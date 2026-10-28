require "rails_helper"

# Desvio 13 (ordem de travas): quem já segura o paciente (FOR UPDATE) e chama o
# comando, contra uma chamada solta para o mesmo paciente e doença. As FKs do
# INSERT tomam FOR KEY SHARE no paciente: se o comando pegasse o lock
# consultivo antes do paciente, as duas se esperariam (deadlock). Travando o
# paciente primeiro, a solta espera e termina em already_notified. Threads
# reais contra TEST_CITY_A (sem fixture transacional), como
# resolve_concurrency_spec.
RSpec.describe "Notificação sob disputa" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let(:ids) { {} }

  before do
    in_city do
      tag = SecureRandom.hex(4)
      ids[:admin] = User.create!(email_address: "vig-#{tag}@c.gov.br", password: "senha-segura-123").id
      ids[:unit] = HealthUnit.create!(name: "UBS Corrida #{tag}", kind: "ubs", cnes: "7654321").id
      ids[:patient] = Patient.create!(cpf: CampaignHistory.cpf_for("vigilancia-#{tag}")).id
    end
  end

  after do
    3.times { release << true }
    threads.each do |t|
      t.join(5) || t.kill
    rescue StandardError
      nil
    end
    in_city do
      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SET LOCAL session_replication_role = replica")
        notification_ids = DiseaseNotification.where(patient_id: ids[:patient]).pluck(:id)
        DiseaseNotificationEvent.where(notification_id: notification_ids).delete_all
        DomainEvent.where("payload->>'notification_id' IN (?)", notification_ids.presence || [ "" ]).delete_all
        DiseaseNotification.where(id: notification_ids).delete_all
        Patient.where(id: ids[:patient]).delete_all
      end
    end
    purge_committed_rows(ids.slice(:admin, :unit))
  end

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  def disease
    @disease ||= in_city do
      Surveillance::Diseases.from_local(LocalNotifiableDisease.new(code: "local_corrida", name: "Corrida", deadline: "weekly",
                                                                    cid10: [], ciap2: [], repeat_after_days: 30, active: true))
    end
  end

  def create!
    Surveillance::CreateNotification.call(patient: Patient.find(ids[:patient]), disease: disease, origin: "manual",
                                          unit: HealthUnit.find(ids[:unit]), by: User.find(ids[:admin]),
                                          suspected_at: Time.current)
  rescue StandardError => e
    e
  end

  it "quem segura o paciente e a chamada solta: uma ok, outra already_notified, sem deadlock" do
    disease
    holding = Queue.new
    first = Queue.new
    threads << holder = Thread.new do
      first << in_city do
        ApplicationRecord.transaction do
          Patient.lock.find(ids[:patient])
          holding << true
          release.pop(timeout: 10) or raise "timeout esperando release"
          create!
        end
      end
    end
    holding.pop(timeout: 5) or raise "a primeira não travou o paciente"

    second = Queue.new
    threads << other = Thread.new { second << in_city { create! } }
    expect(in_city { wait_for_lock_wait }).to be(true)

    release << true
    expect(holder.join(10)).to be(holder)
    expect(other.join(10)).to be(other)
    a = first.pop(timeout: 1)
    b = second.pop(timeout: 1)
    expect([ a, b ]).to all(be_a(Result))
    expect(a).to be_ok
    expect([ b.reason, b.details ]).to eq([ :already_notified, { notification_id: a.payload[:notification].id } ])
    in_city { expect(DiseaseNotification.where(patient_id: ids[:patient]).count).to eq(1) }
  end
end
