require "rails_helper"

# F-13.5 sob disputa: "chamar próximo" trava o candidato com FOR UPDATE SKIP
# LOCKED, então dois profissionais ao mesmo tempo levam atendimentos
# diferentes — sem esperar o lock do outro e sem 409 enquanto a fila ainda tem
# quem chamar. Threads reais contra TEST_CITY_A (sem fixture transacional),
# como spec/commands/professionals/clinical_lock_spec.rb; o after solta as
# threads e apaga tudo o que commitou.
RSpec.describe Attendances::CallNext, "concorrência" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let(:ids) { {} }

  before do
    CityConnection.with(TEST_CITY_A) do
      Current.set(city: TEST_CITY_A) do
        tag = SecureRandom.hex(4)
        # Cada id entra em `ids` assim que a linha nasce: se o before falhar no
        # meio, o after ainda limpa o que já foi commitado.
        admin = User.create!(email_address: "adm-#{tag}@c.gov.br", password: "senha-segura-123")
        ids[:admin] = admin.id
        unit = HealthUnit.create!(name: "UBS Fila #{tag}", kind: "ubs")
        ids[:unit] = unit.id
        ids[:rows] = []
        %w[a b].each do |suffix|
          doctor = User.create!(email_address: "doc-#{suffix}-#{tag}@c.gov.br", password: "senha-segura-123")
          ids[suffix == "a" ? :doctor : :doc_user] = doctor.id
          Membership.create!(user: doctor, role: "health_professional", granted_at: Time.current)
          pro = Professional.create!(user: doctor, professional_name: "P#{suffix}", council: "CRM", council_state: "PR",
                                     registration_number: "#{tag.to_i(16).to_s[0, 7]}#{suffix.ord}",
                                     cns: Professionals::Cns.generate("#{tag}#{suffix}"))
          ProfessionalLink.create!(professional: pro, health_unit: unit, cbo_code: "225125",
                                   started_at: Time.current, started_by_user: admin)
        end
        protocol = ProtocolDefinition.create!(name: "fila-#{tag}", version: 1, status: "draft",
                                              definition: ProtocolDefinition.find_by(name: StartTriage::DEFAULT_PROTOCOL_NAME)&.definition ||
                                                          default_protocol_definition("fila-#{tag}"))
        ids[:protocol] = protocol.id
        # Fila: prioridade 1 (primeiro), 5 (segundo), 9 (terceiro).
        [ 1, 5, 9 ].each_with_index do |priority, i|
          row = {}
          ids[:rows] << row
          citizen = Citizen.create!(cpf: CampaignHistory.cpf_for("fila-#{tag}-#{i}"), phone: "+55419#{format('%08d', 20_000_000 + i)}")
          row[:citizen] = citizen.id
          conversation = Conversation.create!(channel: "web", citizen: citizen, phone: citizen.phone, state: "completed")
          row[:conversation] = conversation.id
          triage = Triage.create!(conversation: conversation, protocol_definition: protocol, protocol_name: protocol.name,
                                  status: "completed", tier: "alta", priority: priority, answers: {},
                                  completed_at: Time.current)
          row[:triage] = triage.id
          attendance = Attendance.create!(triage: triage, citizen: citizen, health_unit: unit, checked_in_by_user: admin,
                                          checked_in_at: Time.current - (10 - i).minutes, check_in_method: "code")
          row[:attendance] = attendance.id
        end
      end
    end
  end

  after do
    3.times { release << true }
    threads.each do |t|
      t.join(5) || t.kill
    rescue StandardError
      nil # join relança a exceção da thread; o exemplo já falhou e a limpeza precisa rodar
    end
    rows = ids.fetch(:rows, [])
    CityConnection.with(TEST_CITY_A) do
      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SET LOCAL session_replication_role = replica")
        attendance_ids = rows.pluck(:attendance)
        DomainEvent.where("payload->>'attendance_id' IN (?)", attendance_ids.presence || [ "" ]).delete_all
        Attendance.where(id: attendance_ids).delete_all
        Triage.where(id: rows.pluck(:triage)).delete_all
        Conversation.where(id: rows.pluck(:conversation)).delete_all
        Citizen.where(id: rows.pluck(:citizen)).delete_all
        ProtocolDefinition.where(id: ids[:protocol]).delete_all
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

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A) { ApplicationRecord.transaction(&) } }
  def attendance_ids = ids[:rows].pluck(:attendance)
  def status_of(id) = CityConnection.with(TEST_CITY_A) { Attendance.find(id).status }

  def call_next(user_key)
    CityConnection.with(TEST_CITY_A) do
      Current.set(city: TEST_CITY_A) { described_class.call(health_unit_id: ids[:unit], by: User.find(ids[user_key])) }
    end
  end

  it "dois profissionais ao mesmo tempo levam atendimentos diferentes, sem esperar e sem 409" do
    holding = Queue.new
    holder = nil
    original = DomainEvents.method(:publish)
    allow(DomainEvents).to receive(:publish) do |*args, **kwargs, &blk|
      result = original.call(*args, **kwargs, &blk)
      if Thread.current == holder && args.first == "attendance.called"
        holding << true
        release.pop(timeout: 10) or raise "timeout esperando release"
      end
      result
    end

    first_result = Queue.new
    threads << (holder = Thread.new { first_result << call_next(:doctor) })
    holding.pop(timeout: 5) or raise "o primeiro chamar próximo não travou o atendimento"

    second_result = Queue.new
    threads << second = Thread.new { second_result << call_next(:doc_user) }
    # Sem SKIP LOCKED o segundo pararia no FOR UPDATE do primeiro.
    expect(second.join(5)).to be(second)
    second_call = second_result.pop(timeout: 1)
    expect(second_call).to be_ok
    expect(second_call.payload[:attendance].id).to eq(attendance_ids[1])

    release << true
    expect(holder.join(5)).to be(holder)
    first_call = first_result.pop(timeout: 1)
    expect(first_call).to be_ok
    expect(first_call.payload[:attendance].id).to eq(attendance_ids[0])
    expect(attendance_ids.first(2).map { status_of(_1) }).to eq(%w[in_care in_care])
    expect(status_of(attendance_ids[2])).to eq("waiting")
  end

  it "pula a linha travada por outra transação (ex.: desfecho em curso) e chama a seguinte" do
    locked = Queue.new
    threads << locker = Thread.new do
      in_city do
        Attendance.lock.find(attendance_ids[0])
        locked << true
        release.pop(timeout: 10) or raise "timeout esperando release"
      end
    end
    locked.pop(timeout: 5) or raise "a outra transação não travou o primeiro da fila"

    result = Queue.new
    threads << caller_thread = Thread.new { result << call_next(:doctor) }
    expect(caller_thread.join(5)).to be(caller_thread)
    call = result.pop(timeout: 1)
    expect(call).to be_ok
    expect(call.payload[:attendance].id).to eq(attendance_ids[1])

    release << true
    expect(locker.join(5)).to be(locker)
    expect(status_of(attendance_ids[0])).to eq("waiting")
  end
  it "dois profissionais chamando o MESMO atendimento: o segundo espera o lock e recebe already_called" do
    holding = Queue.new
    holder = nil
    original = DomainEvents.method(:publish)
    allow(DomainEvents).to receive(:publish) do |*args, **kwargs, &blk|
      result = original.call(*args, **kwargs, &blk)
      if Thread.current == holder && args.first == "attendance.called"
        holding << true
        release.pop(timeout: 10) or raise "timeout esperando release"
      end
      result
    end
    call_one = lambda do |user_key|
      CityConnection.with(TEST_CITY_A) do
        Current.set(city: TEST_CITY_A) do
          Attendances::Call.call(attendance: Attendance.find(attendance_ids[0]), health_unit_id: ids[:unit],
                                 by: User.find(ids[user_key]))
        end
      end
    end

    first_result = Queue.new
    threads << (holder = Thread.new { first_result << call_one.call(:doctor) })
    holding.pop(timeout: 5) or raise "o primeiro não travou o atendimento"

    second_result = Queue.new
    threads << second = Thread.new { second_result << call_one.call(:doc_user) }
    expect(wait_for_lock_wait).to be(true) # o segundo espera o FOR UPDATE do primeiro

    release << true
    expect(holder.join(5)).to be(holder)
    expect(second.join(5)).to be(second)
    expect(first_result.pop(timeout: 1)).to be_ok
    expect(second_result.pop(timeout: 1).reason).to eq(:already_called)
    called_by = CityConnection.with(TEST_CITY_A) { Attendance.find(attendance_ids[0]).called_by_user_id }
    expect(called_by).to eq(ids[:doctor])
  end
end
