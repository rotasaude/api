# spec/commands/appointments/booking_concurrency_spec.rb
require "rails_helper"

# ADR 0029 §4.3 sob disputa, com threads reais contra TEST_CITY_A (sem fixture
# transacional), no padrão de spec/commands/attendances/call_next_concurrency_spec.rb.
# A primeira marcação para DENTRO da transação (no publish de appointment.booked,
# depois do INSERT); a segunda tem de esperar o lock e decidir só depois do
# COMMIT da primeira. O after solta as threads e apaga tudo o que commitou.
RSpec.describe "Marcação sob disputa" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let(:started_at) { Time.current }
  let(:ids) { { users: [], pros: [], links: [], shifts: [], citizens: [], conversations: [], triages: [], requests: [] } }

  before do
    started_at
    CityConnection.with(TEST_CITY_A) do
      Current.set(city: TEST_CITY_A) do
        tag = SecureRandom.hex(4)
        ids[:types] = Scheduling::AppointmentTypes.seed_platform!.positive?
        admin = User.create!(email_address: "adm-#{tag}@c.gov.br", password: "senha-segura-123")
        ids[:admin] = admin.id
        unit = HealthUnit.create!(name: "UBS Agenda #{tag}", kind: "ubs")
        ids[:unit] = unit.id
        template = ScheduleTemplate.create!(name: "Limite um #{tag}", fit_in_limit: 1, blocks: [])
        ids[:template] = template.id
        starts = (Time.zone.today + 3).in_time_zone.change(hour: 8)
        ids[:starts] = starts
        %w[a b].each_with_index do |suffix, i|
          user = User.create!(email_address: "doc-#{suffix}-#{tag}@c.gov.br", password: "senha-segura-123")
          ids[:users] << user.id
          Membership.create!(user: user, role: "health_professional", granted_at: Time.current)
          pro = Professional.create!(user: user, professional_name: "P#{suffix}", council: "CRM", council_state: "PR",
                                     registration_number: "#{tag.to_i(16).to_s[0, 7]}#{i}",
                                     cns: Professionals::Cns.generate("#{tag}#{suffix}"))
          ids[:pros] << pro.id
          ids[:"pro_#{suffix}"] = pro.id
          link = ProfessionalLink.create!(professional: pro, health_unit: unit, cbo_code: "225125",
                                          started_at: Time.current, started_by_user: admin)
          ids[:links] << link.id
          shift = ProfessionalShift.create!(professional_link: link, professional_id: pro.id, starts_at: starts,
                                            ends_at: starts + 2.hours, created_by_user: admin,
                                            schedule_template: suffix == "b" ? template : nil)
          ids[:shifts] << shift.id
          ids[:"shift_#{suffix}"] = shift.id
        end
        protocol = ProtocolDefinition.create!(
          name: "agenda-#{tag}", version: 1, status: "draft",
          definition: { "name" => "agenda-#{tag}", "version" => 1, "start_step_id" => "q1",
                        "steps" => [ { "id" => "q1", "prompt" => "?", "answer_type" => "boolean",
                                       "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 1, "false" => 0 } } ],
                        "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 }, "priority_map" => { "baixa" => 9 } } }
        )
        ids[:protocol] = protocol.id
        # r0, r1, r2: três cidadãos; r3: o cidadão de r0, outro tipo (um pedido de triagem vivo por tipo).
        [ [ 0, "consulta_medica" ], [ 1, "consulta_medica" ], [ 2, "consulta_medica" ], [ 0, "retorno" ] ].each do |n, key|
          citizen = ids[:citizens][n] ? Citizen.find(ids[:citizens][n]) :
                      Citizen.create!(cpf: CampaignHistory.cpf_for("agenda-#{tag}-#{n}"), phone: "+55419#{format('%08d', 40_000_000 + n)}")
          ids[:citizens][n] ||= citizen.id
          conversation = Conversation.create!(channel: "web", citizen: citizen, phone: citizen.phone, state: "completed")
          ids[:conversations] << conversation.id
          triage = Triage.create!(conversation: conversation, protocol_definition: protocol, protocol_name: protocol.name,
                                  status: "completed", tier: "baixa", priority: 9, answers: {}, completed_at: Time.current)
          ids[:triages] << triage.id
          request = AppointmentRequest.create!(kind: "triage", origin_triage: triage, root_triage: triage, citizen: citizen,
                                               target_unit: unit, appointment_type_key: key)
          ids[:requests] << request.id
        end
      end
    end
  end

  after do
    3.times { release << true }
    threads.each do |t|
      t.join(5) || t.kill
    rescue StandardError
      nil # join relança a exceção da thread; a limpeza precisa rodar mesmo assim
    end
    CityConnection.with(TEST_CITY_A) do
      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SET LOCAL session_replication_role = replica")
        # Eventos: as threads publicam com ids gerados lá dentro; os bancos de
        # teste rodam um exemplo por vez, então "depois do início" é só deste.
        DomainEvent.where(created_at: started_at..).delete_all
        Appointment.where(request_id: ids[:requests]).delete_all
        AppointmentRequestTriage.where(triage_id: ids[:triages]).delete_all
        AppointmentRequest.where(id: ids[:requests]).delete_all
        Triage.where(id: ids[:triages]).delete_all
        Conversation.where(id: ids[:conversations]).delete_all
        Citizen.where(id: ids[:citizens].compact).delete_all
        ProtocolDefinition.where(id: ids[:protocol]).delete_all
        ProfessionalShift.where(id: ids[:shifts]).delete_all
        ScheduleTemplate.where(id: ids[:template]).delete_all
        ProfessionalLink.where(id: ids[:links]).delete_all
        Professional.where(id: ids[:pros]).delete_all
        user_ids = ids[:users] + [ ids[:admin] ].compact
        Session.where(user_id: user_ids).delete_all
        Membership.where(user_id: user_ids).delete_all
        User.where(id: user_ids).delete_all
        HealthUnit.where(id: ids[:unit]).delete_all
        AppointmentType.where(origin: "platform").delete_all if ids[:types] # só a base que este exemplo semeou
      end
    end
  end

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  # Exceção dentro da thread vira o valor devolvido, para o exemplo afirmar
  # sobre ela em vez de perdê-la (e esperar o timeout da fila).
  def capture
    yield
  rescue StandardError => e
    e
  end

  # A thread que chama isto para DENTRO da transação, logo depois do INSERT.
  def hold_after_insert!(holding)
    holder = Thread.current
    original = DomainEvents.method(:publish)
    allow(DomainEvents).to receive(:publish) do |*args, **kwargs, &blk|
      result = original.call(*args, **kwargs, &blk)
      if Thread.current == holder && args.first == "appointment.booked"
        holding << true
        release.pop(timeout: 10) or raise "timeout esperando release"
      end
      result
    end
  end

  def book(request_index, pro, at)
    capture do
      in_city do
        Appointments::Book.call(request: AppointmentRequest.find(ids[:requests][request_index]),
                                professional: Professional.find(ids[pro]), starts_at: at.iso8601,
                                type: AppointmentType.find_by!(key: "consulta_medica"),
                                by: User.find(ids[:admin])).reason || :ok
      end
    end
  end

  def fit_in(request_index, at)
    capture do
      in_city do
        Appointments::FitIn.call(request: AppointmentRequest.find(ids[:requests][request_index]),
                                 professional: Professional.find(ids[:pro_b]), shift: ProfessionalShift.find(ids[:shift_b]),
                                 starts_at: at.iso8601, type: AppointmentType.find_by!(key: "consulta_medica"),
                                 reason: "retorno que não espera", by: User.find(ids[:admin])).reason || :ok
      end
    end
  end

  # Roda `first` numa thread que segura a transação; `second` noutra; prova que
  # a segunda espera um lock; solta a primeira e devolve [primeira, segunda].
  def race(first, second)
    holding = Queue.new
    outcomes = [ Queue.new, Queue.new ]
    threads << Thread.new { hold_after_insert!(holding); outcomes[0] << first.call }
    holding.pop(timeout: 5) or raise "a primeira marcação não chegou ao INSERT"
    threads << Thread.new { outcomes[1] << second.call }
    expect(wait_for_lock_wait).to be(true)
    release << true
    [ outcomes[0].pop(timeout: 10), outcomes[1].pop(timeout: 10) ]
  end

  def active_count(**where)
    in_city { Appointment.where(request_id: ids[:requests], status: Appointment::ACTIVE, **where).count }
  end

  it "duas recepções na mesma vaga: uma marca, a outra recebe slot_taken" do
    at = ids[:starts]
    expect(race(-> { book(0, :pro_a, at) }, -> { book(1, :pro_a, at) })).to eq([ :ok, :slot_taken ])
    expect(active_count).to eq(1)
  end

  it "dois encaixes no último lugar do limite: um passa, o outro recebe fit_in_limit" do
    at = ids[:starts] + 10.minutes
    expect(race(-> { fit_in(0, at) }, -> { fit_in(1, at + 30.minutes) })).to eq([ :ok, :fit_in_limit ])
    expect(active_count(shift_id: ids[:shift_b], booking_kind: "fit_in")).to eq(1)
  end

  it "o mesmo cidadão em dois profissionais na mesma hora: o segundo recebe citizen_busy" do
    at = ids[:starts]
    in_city { ProfessionalShift.find(ids[:shift_b]).update!(schedule_template_id: nil) }
    expect(race(-> { book(0, :pro_a, at) }, -> { book(3, :pro_b, at) })).to eq([ :ok, :citizen_busy ])
    expect(active_count(citizen_id: ids[:citizens][0])).to eq(1)
  end
end
