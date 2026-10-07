# spec/commands/screenings/screening_concurrency_spec.rb
require "rails_helper"

# Review Focus 1 (ADR 0030): duas profissionais na mesma pessoa ao mesmo
# tempo — uma escuta só; a chamada do médico no meio da conclusão — a escuta
# vira abandonada e a conclusão recebe not_in_progress, nunca 500 nem
# atendimento fechado duas vezes. Threads reais contra TEST_CITY_A (sem
# fixture transacional), como spec/commands/attendances/call_next_concurrency_spec.rb.
RSpec.describe "Escuta inicial sob disputa" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let(:ids) { {} }

  before do
    CityConnection.with(TEST_CITY_A) do
      Current.set(city: TEST_CITY_A) do
        tag = SecureRandom.hex(4)
        admin = User.create!(email_address: "adm-#{tag}@c.gov.br", password: "senha-segura-123")
        ids[:admin] = admin.id
        unit = HealthUnit.create!(name: "UBS Escuta #{tag}", kind: "ubs")
        ids[:unit] = unit.id
        { doctor: "223505", doc_user: "225125" }.each do |key, cbo|
          user = User.create!(email_address: "#{key}-#{tag}@c.gov.br", password: "senha-segura-123")
          ids[key] = user.id
          Membership.create!(user: user, role: "health_professional", granted_at: Time.current)
          pro = Professional.create!(user: user, professional_name: "P#{key}", council: "COREN", council_state: "PR",
                                     registration_number: "#{tag.to_i(16).to_s[0, 6]}#{key == :doctor ? 1 : 2}",
                                     cns: Professionals::Cns.generate("#{tag}#{key}"))
          ProfessionalLink.create!(professional: pro, health_unit: unit, cbo_code: cbo, started_at: Time.current,
                                   started_by_user: admin)
        end
        citizen = Citizen.create!(cpf: CampaignHistory.cpf_for("escuta-#{tag}"), phone: "+55419#{tag.to_i(16).to_s[0, 8].rjust(8, '1')}")
        ids[:citizen] = citizen.id
        definition = { "name" => "escuta-#{tag}", "version" => 1, "start_step_id" => "tosse",
                       "steps" => [ { "id" => "tosse", "prompt" => "?", "answer_type" => "boolean",
                                      "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 5, "false" => 0 } } ],
                       "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 }, "priority_map" => { "baixa" => 9 } } }
        protocol = ProtocolDefinition.create!(name: definition["name"], version: 1, status: "draft", definition: definition)
        ids[:protocol] = protocol.id
        conversation = Conversation.create!(channel: "web", citizen: citizen, phone: citizen.phone, state: "completed")
        ids[:conversation] = conversation.id
        triage = Triage.create!(conversation: conversation, protocol_definition: protocol, protocol_name: protocol.name,
                                status: "completed", tier: "baixa", priority: 9, answers: {}, completed_at: Time.current)
        ids[:triage] = triage.id
        attendance = Attendance.create!(triage: triage, citizen: citizen, health_unit: unit, checked_in_by_user: admin,
                                        checked_in_at: Time.current, check_in_method: "code")
        ids[:attendance] = attendance.id
      end
    end
    allow(Screenings::Ciap2).to receive(:find)
      .and_return(Screenings::Ciap2::Code.new(code: "K86", label: "Hipertensão", release_id: SecureRandom.uuid))
  end

  after do
    3.times { release << true }
    threads.each do |t|
      t.join(5) || t.kill
    rescue StandardError
      nil
    end
    CityConnection.with(TEST_CITY_A) do
      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SET LOCAL session_replication_role = replica")
        screening_ids = Screening.where(attendance_id: ids[:attendance]).pluck(:id)
        DomainEvent.where("payload->>'attendance_id' = ? OR payload->>'screening_id' IN (?)", ids[:attendance].to_s,
                          screening_ids.presence || [ "" ]).delete_all
        AppointmentRequest.where(origin_attendance_id: ids[:attendance]).delete_all
        Screening.where(id: screening_ids).update_all(current_revision_id: nil)
        ScreeningRevision.where(screening_id: screening_ids).delete_all
        Screening.where(id: screening_ids).delete_all
        Attendance.where(id: ids[:attendance]).delete_all
        Triage.where(id: ids[:triage]).delete_all
        Conversation.where(id: ids[:conversation]).delete_all
        Citizen.where(id: ids[:citizen]).delete_all
        ProtocolDefinition.where(id: ids[:protocol]).delete_all
      end
    end
    purge_committed_rows(ids)
  end

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }
  def attendance = Attendance.find(ids[:attendance])

  def hold_on(event_name)
    holder = nil
    holding = Queue.new
    original = DomainEvents.method(:publish)
    allow(DomainEvents).to receive(:publish) do |*args, **kwargs, &blk|
      result = original.call(*args, **kwargs, &blk)
      if Thread.current == holder && args.first == event_name
        holding << true
        release.pop(timeout: 10) or raise "timeout esperando release"
      end
      result
    end
    [ holding, ->(thread) { holder = thread } ]
  end

  it "duas iniciam juntas: a segunda espera o lock e recebe already_screening; uma escuta só" do
    holding, mark = hold_on("screening.started")
    first = Queue.new
    go = Queue.new
    threads << (holder = Thread.new do
      go.pop(timeout: 5)
      first << in_city { Screenings::Start.call(attendance: attendance, by: User.find(ids[:doctor])) }
    end)
    mark.call(holder)
    go << true
    holding.pop(timeout: 5) or raise "a primeira não travou o atendimento"

    second = Queue.new
    threads << other = Thread.new { second << in_city { Screenings::Start.call(attendance: attendance, by: User.find(ids[:doc_user])) } }
    expect(wait_for_lock_wait).to be(true)

    release << true
    expect(holder.join(5)).to be(holder)
    expect(other.join(5)).to be(other)
    expect(first.pop(timeout: 1)).to be_ok
    expect(second.pop(timeout: 1).reason).to eq(:already_screening)
    expect(in_city { Screening.where(attendance_id: ids[:attendance]).count }).to eq(1)
  end

  it "a chamada vence a conclusão: escuta abandonada, conclusão recebe not_in_progress, atendimento em atendimento" do
    screening = in_city { Screenings::Start.call(attendance: attendance, by: User.find(ids[:doctor])).payload[:screening] }
    holding, mark = hold_on("attendance.called")
    called = Queue.new
    go = Queue.new
    threads << (holder = Thread.new do
      go.pop(timeout: 5)
      called << in_city { Attendances::Call.call(attendance: attendance, health_unit_id: ids[:unit], by: User.find(ids[:doc_user])) }
    end)
    mark.call(holder)
    go << true
    holding.pop(timeout: 5) or raise "a chamada não travou o atendimento"

    completed = Queue.new
    threads << completer = Thread.new do
      completed << in_city do
        Screenings::Complete.call(screening: Screening.find(screening.id), revision_params: revision_params,
                                  destination: "oriented", destination_params: { "orientation_note" => "repouso e água" },
                                  by: User.find(ids[:doctor]))
      end
    end
    expect(wait_for_lock_wait).to be(true)

    release << true
    expect(holder.join(5)).to be(holder)
    expect(completer.join(5)).to be(completer)
    expect(called.pop(timeout: 1)).to be_ok
    expect(completed.pop(timeout: 1).reason).to eq(:not_in_progress)
    in_city do
      expect(Screening.find(screening.id).status).to eq("abandoned")
      expect(ScreeningRevision.where(screening_id: screening.id)).to be_empty
      expect(attendance.status).to eq("in_care")
    end
  end
end
