require "rails_helper"

# Exclusão do cadastro × lembrete da véspera (revisão PM-B, Important 1).
# Citizens::Erase trava o cidadão em FOR UPDATE e depois os horários vivos do
# par. O Appointments::Remind travava o horário e só então gravava o aviso,
# cuja FK pega KEY SHARE no cidadão: Remind segurava o horário e esperava o
# cidadão; Erase segurava o cidadão e esperava o horário (ActiveRecord::Deadlocked).
# Com o cidadão em KEY SHARE antes do horário, o Remind segue a ordem global.
# Threads reais contra TEST_CITY_A, como erase_drain_concurrency_spec.rb.
RSpec.describe Citizens::Erase, "concorrência com Remind" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let(:ids) { {} }

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  before do
    in_city do
      ids[:started_at] = Time.current
      ids[:types] = Scheduling::AppointmentTypes.seed_platform!.positive?
      tag = SecureRandom.hex(4)
      ids[:admin] = User.create!(email_address: "adm-#{tag}@c.gov.br", password: "senha-segura-123").id
      ids[:verifier] = User.create!(email_address: "ver-#{tag}@c.gov.br", password: "senha-segura-123").id
      ids[:unit] = HealthUnit.create!(name: "UBS Lembrete #{tag}", kind: "ubs").id
      protocol = ProtocolDefinition.create!(name: "remind-#{tag}", version: 1, status: "draft",
                                            definition: default_protocol_definition("remind-#{tag}"))
      ids[:protocol] = protocol.id
      cpf = CampaignHistory.cpf_for("remind-#{tag}")
      citizen = Citizen.create!(cpf: cpf, phone: "+55419#{format('%08d', 60_000_000 + SecureRandom.random_number(1_000_000))}")
      ids[:citizen] = citizen.id
      conversation = Conversation.create!(channel: "web", citizen: citizen, phone: citizen.phone, state: "completed")
      ids[:conversation] = conversation.id
      Consent.create!(conversation: conversation, version: 1, policy_text_sha: "sha", channel: "web",
                      given_at: 1.hour.ago)
      triage = Triage.create!(conversation: conversation, protocol_definition: protocol, protocol_name: protocol.name,
                              status: "completed", tier: "alta", priority: 1, answers: {}, completed_at: Time.current)
      ids[:triage] = triage.id
      request = AppointmentRequest.create!(kind: "triage", origin_triage: triage, root_triage: triage, citizen: citizen,
                                           target_unit_id: ids[:unit], appointment_type_key: "consulta_medica")
      request.update!(status: "scheduled")
      ids[:request] = request.id
      # Horário livre (legacy) confirmado para amanhã: o lembrete da véspera o pega.
      ids[:appointment] = Appointment.create!(request: request, citizen: citizen, health_unit_id: ids[:unit],
                                              scheduled_at: 1.day.from_now.change(hour: 9),
                                              scheduled_by_user_id: ids[:admin], status: "confirmed",
                                              confirmed_at: Time.current).id
      ids[:erasure] = CitizenErasureRequest.create!(cpf: cpf, presented_citizen: citizen,
                                                    requested_by_user_id: ids[:verifier],
                                                    document_checked: true, status: "pending").id
    end
  end

  after do
    3.times { release << true }
    threads.each do |t|
      t.join(5) || t.kill
    rescue StandardError
      nil # join relança a exceção da thread; o exemplo já falhou e a limpeza precisa rodar
    end
    in_city do
      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SET LOCAL session_replication_role = replica")
        DomainEvent.where(created_at: ids[:started_at]..).delete_all if ids[:started_at]
        AppointmentNotice.where(citizen_id: ids[:citizen]).delete_all
        Appointment.where(citizen_id: ids[:citizen]).delete_all
        request_ids = AppointmentRequest.where(citizen_id: ids[:citizen]).pluck(:id)
        AppointmentRequestTriage.where(request_id: request_ids).delete_all
        AppointmentRequest.where(id: request_ids).delete_all
        CitizenErasureRequest.where(id: ids[:erasure]).delete_all
        Triage.where(id: ids[:triage]).delete_all
        Consent.where(conversation_id: ids[:conversation]).delete_all
        Conversation.where(id: ids[:conversation]).delete_all
        Citizen.where(id: ids[:citizen]).delete_all
        ProtocolDefinition.where(id: ids[:protocol]).delete_all
        User.where(id: ids[:verifier]).delete_all
        AppointmentType.where(origin: "platform").delete_all if ids[:types]
      end
    end
    purge_committed_rows(ids)
  end

  def default_protocol_definition(name)
    { "name" => name, "version" => 1, "start_step_id" => "tosse",
      "steps" => [ { "id" => "tosse", "prompt" => "Você está com tosse?", "answer_type" => "boolean",
                     "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 5, "false" => 0 } } ],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0, "alta" => 5 },
                     "priority_map" => { "baixa" => 9, "alta" => 1 } } }
  end

  # Exceção (ex.: ActiveRecord::Deadlocked) vira o valor devolvido.
  def capture
    yield
  rescue StandardError => e
    e
  end

  def erase
    capture do
      in_city { described_class.call(request: CitizenErasureRequest.find(ids[:erasure]), by: User.find(ids[:admin])) }
    end
  end

  def remind
    capture { in_city { Appointments::Remind.call(appointment: Appointment.find(ids[:appointment])) } }
  end

  def appointment = in_city { Appointment.find(ids[:appointment]) }
  def request_row = in_city { AppointmentRequest.find(ids[:request]) }
  def notices = in_city { AppointmentNotice.where(appointment_id: ids[:appointment]).count }

  it "lembrete já com o horário travado, exclusão chega: sem deadlock, a exclusão cancela depois" do
    holding = Queue.new
    holder = nil
    # Logo depois das travas do Remind (cidadão → horário), antes de gravar o aviso.
    allow(AppointmentNotice).to receive(:exists?).and_wrap_original do |original, *args, **kwargs|
      if Thread.current == holder
        holding << true
        release.pop(timeout: 10) or raise "timeout esperando release"
      end
      original.call(*args, **kwargs)
    end

    remind_result = Queue.new
    threads << (holder = Thread.new { remind_result << remind })
    holding.pop(timeout: 5) or raise "o lembrete não chegou às travas"

    erase_result = Queue.new
    threads << eraser = Thread.new { erase_result << erase }
    expect(in_city { wait_for_lock_wait }).to be(true)

    release << true
    expect(holder.join(10)).to be(holder)
    expect(eraser.join(10)).to be(eraser)
    reminded = remind_result.pop(timeout: 1)
    erased = erase_result.pop(timeout: 1)
    expect(reminded).to be_a(Result).and be_ok
    expect(erased).to be_a(Result).and be_ok
    expect(appointment).to have_attributes(status: "cancelled_by_citizen", reminded_at: be_present,
                                           cancel_reason: Appointment::ERASURE_CANCEL_REASON)
    expect(notices).to eq(0)
    expect(request_row).to have_attributes(status: "closed", closed_reason: "consent_revoked")
  end

  it "exclusão já com as travas, lembrete chega: o lembrete espera e não age no horário cancelado" do
    holding = Queue.new
    holder = nil
    allow(described_class).to receive(:erase_pair).and_wrap_original do |original, *args|
      if Thread.current == holder
        holding << true
        release.pop(timeout: 10) or raise "timeout esperando release"
      end
      original.call(*args)
    end

    erase_result = Queue.new
    threads << (holder = Thread.new { erase_result << erase })
    holding.pop(timeout: 5) or raise "a exclusão não chegou às travas"

    remind_result = Queue.new
    threads << reminder = Thread.new { remind_result << remind }
    expect(in_city { wait_for_lock_wait }).to be(true)

    release << true
    expect(holder.join(10)).to be(holder)
    expect(reminder.join(10)).to be(reminder)
    expect(erase_result.pop(timeout: 1)).to be_a(Result).and be_ok
    reminded = remind_result.pop(timeout: 1)
    expect(reminded).to be_a(Result).and be_ok
    expect(reminded.payload).to eq(skipped: :not_due)
    expect(appointment).to have_attributes(status: "cancelled_by_citizen", reminded_at: nil)
    expect(notices).to eq(0)
  end
end
