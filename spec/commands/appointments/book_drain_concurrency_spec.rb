require "rails_helper"

# Marcação × esvaziamento da mesma unidade (revisão da Task 9): HealthUnits::Drain
# trava a unidade (FOR UPDATE) → horários → pedidos; Book trava a unidade
# (FOR SHARE) → cidadão → horários → pedido. Com a unidade por último no Book,
# os dois cruzados davam ActiveRecord::Deadlocked (500). Threads reais contra
# TEST_CITY_A (sem fixture transacional), como
# spec/commands/attendances/call_next_concurrency_spec.rb; o after solta as
# threads e apaga tudo o que commitou.
RSpec.describe Appointments::Book, "concorrência com Drain" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let(:ids) { {} }
  let(:started_at) { Time.current }

  before do
    started_at
    CityConnection.with(TEST_CITY_A) do
      Current.set(city: TEST_CITY_A) do
        ids[:types] = Scheduling::AppointmentTypes.seed_platform!.positive?
        tag = SecureRandom.hex(4)
        # Cada id entra em `ids` assim que a linha nasce: se o before falhar no
        # meio, o after ainda limpa o que já foi commitado.
        admin = User.create!(email_address: "adm-#{tag}@c.gov.br", password: "senha-segura-123")
        ids[:admin] = admin.id
        ids[:unit] = HealthUnit.create!(name: "UBS Fecha #{tag}", kind: "ubs").id
        ids[:dest] = HealthUnit.create!(name: "UBS Destino #{tag}", kind: "ubs").id
        doctor = User.create!(email_address: "doc-#{tag}@c.gov.br", password: "senha-segura-123")
        ids[:doctor] = doctor.id
        Membership.create!(user: doctor, role: "health_professional", granted_at: Time.current)
        pro = Professional.create!(user: doctor, professional_name: "Pa", council: "CRM", council_state: "PR",
                                   registration_number: "#{tag.to_i(16).to_s[0, 7]}1",
                                   cns: Professionals::Cns.generate("#{tag}a"))
        ids[:professional] = pro.id
        link = ProfessionalLink.create!(professional: pro, health_unit_id: ids[:unit], cbo_code: "225125",
                                        started_at: Time.current, started_by_user: admin)
        day = Time.zone.today + 5
        shift = ProfessionalShift.create!(professional_link: link, professional_id: pro.id, created_by_user: admin,
                                          starts_at: day.in_time_zone.change(hour: 8),
                                          ends_at: day.in_time_zone.change(hour: 10))
        ids[:starts_at] = shift.starts_at
        protocol = ProtocolDefinition.create!(
          name: "book-#{tag}", version: 1, status: "draft",
          definition: ProtocolDefinition.find_by(name: StartTriage::DEFAULT_PROTOCOL_NAME)&.definition ||
                      default_protocol_definition("book-#{tag}")
        )
        ids[:protocol] = protocol.id
        citizen = Citizen.create!(cpf: CampaignHistory.cpf_for("book-#{tag}"), phone: "+5541920000099")
        ids[:citizen] = citizen.id
        conversation = Conversation.create!(channel: "web", citizen: citizen, phone: citizen.phone, state: "completed")
        ids[:conversation] = conversation.id
        triage = Triage.create!(conversation: conversation, protocol_definition: protocol, protocol_name: protocol.name,
                                status: "completed", tier: "alta", priority: 1, answers: {}, completed_at: Time.current)
        ids[:triage] = triage.id
        # Pedido de retorno (origem atendimento): o Drain ainda não sabe mover
        # pedido de triagem (o plano o ensina a copiar a origem numa task adiante).
        attendance = Attendance.create!(triage: triage, citizen: citizen, health_unit_id: ids[:unit],
                                        checked_in_by_user: admin, checked_in_at: Time.current, check_in_method: "code")
        ids[:attendance] = attendance.id
        ids[:request] = AppointmentRequest.create!(kind: "return", origin_attendance: attendance, root_triage: triage,
                                                   citizen: citizen, origin_unit_id: ids[:unit],
                                                   target_unit_id: ids[:unit],
                                                   appointment_type_key: "consulta_medica").id
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
    CityConnection.with(TEST_CITY_A) do
      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SET LOCAL session_replication_role = replica")
        # Eventos: os threads publicam com ids gerados lá dentro; os bancos de
        # teste rodam um exemplo por vez, então "depois do início" é só deste.
        DomainEvent.where(created_at: started_at..).delete_all
        unit_ids = ids.values_at(:unit, :dest).compact
        HealthUnitDrain.where(health_unit_id: unit_ids).delete_all
        Appointment.where(citizen_id: ids[:citizen]).delete_all
        AppointmentRequestTriage.where(triage_id: ids[:triage]).delete_all
        AppointmentRequest.where(citizen_id: ids[:citizen]).delete_all
        Attendance.where(id: ids[:attendance]).delete_all
        Triage.where(id: ids[:triage]).delete_all
        Conversation.where(id: ids[:conversation]).delete_all
        Citizen.where(id: ids[:citizen]).delete_all
        ProtocolDefinition.where(id: ids[:protocol]).delete_all
        HealthUnit.where(id: ids[:dest]).delete_all
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

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  # Exceção (ex.: ActiveRecord::Deadlocked) vira o valor devolvido, para o
  # exemplo afirmar sobre ela em vez de perdê-la dentro da thread.
  def capture
    yield
  rescue StandardError => e
    e
  end

  def book
    capture do
      in_city do
        described_class.call(request: AppointmentRequest.find(ids[:request]),
                             professional: Professional.find(ids[:professional]),
                             starts_at: ids[:starts_at].iso8601, type: AppointmentType.find_by!(key: "consulta_medica"),
                             by: User.find(ids[:admin]))
      end
    end
  end

  def drain
    capture do
      in_city do
        HealthUnits::Drain.call(unit: HealthUnit.find(ids[:unit]), target_unit_id: ids[:dest],
                                reason: "unidade fechada para reforma", by: User.find(ids[:admin]))
      end
    end
  end

  def request_status = in_city { AppointmentRequest.find(ids[:request]).reload.status }

  it "marcação já com as travas, esvaziamento chega: o Drain espera e leva o horário recém-marcado" do
    holding = Queue.new
    holder = nil
    allow(Appointments::Placement).to receive(:lock!).and_wrap_original do |original, *args|
      original.call(*args).tap do
        if Thread.current == holder
          holding << true
          release.pop(timeout: 10) or raise "timeout esperando release"
        end
      end
    end

    book_result = Queue.new
    threads << (holder = Thread.new { book_result << book })
    holding.pop(timeout: 5) or raise "a marcação não chegou às travas"

    drain_result = Queue.new
    threads << drainer = Thread.new { drain_result << drain }
    expect(in_city { wait_for_lock_wait }).to be(true) # o Drain espera a unidade (FOR UPDATE × FOR SHARE)

    release << true
    expect(holder.join(10)).to be(holder)
    expect(drainer.join(10)).to be(drainer)
    booked = book_result.pop(timeout: 1)
    drained = drain_result.pop(timeout: 1)
    expect(booked).to be_a(Result).and be_ok
    expect(drained).to be_a(Result).and be_ok
    expect(drained.payload).to include(requests: 1, appointments: 1)
    expect(request_status).to eq("closed")
    expect(in_city { Appointment.find(booked.payload[:appointment].id).status }).to eq("moved")
  end

  it "esvaziamento já com as travas, marcação chega: o Book espera e recebe request_not_open" do
    holding = Queue.new
    holder = nil
    original = DomainEvents.method(:publish)
    allow(DomainEvents).to receive(:publish) do |*args, **kwargs, &blk|
      result = original.call(*args, **kwargs, &blk)
      if Thread.current == holder && args.first == "health_unit.drained"
        holding << true
        release.pop(timeout: 10) or raise "timeout esperando release"
      end
      result
    end

    drain_result = Queue.new
    threads << (holder = Thread.new { drain_result << drain })
    holding.pop(timeout: 5) or raise "o esvaziamento não chegou às travas"

    book_result = Queue.new
    threads << booker = Thread.new { book_result << book }
    expect(in_city { wait_for_lock_wait }).to be(true) # o Book espera a unidade

    release << true
    expect(holder.join(10)).to be(holder)
    expect(booker.join(10)).to be(booker)
    expect(drain_result.pop(timeout: 1)).to be_a(Result).and be_ok
    booked = book_result.pop(timeout: 1)
    expect(booked).to be_a(Result)
    expect(booked.reason).to eq(:request_not_open)
    expect(in_city { Appointment.where(citizen_id: ids[:citizen]).count }).to eq(0)
  end
end
