require "rails_helper"

# ScheduleShift (FOR SHARE no vínculo) e EndLink (FOR UPDATE) se excluem:
# ou o turno entra antes e é cancelado pelo encerramento (se futuro), ou o
# lançamento espera e vê o vínculo encerrado. Threads reais, sem fixture
# transacional — mesmo padrão de spec/models/health_unit_lock_spec.rb.
RSpec.describe "Vínculo: encerrar × lançar turno" do
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
        doc_user = User.create!(email_address: "doc-#{tag}@c.gov.br", password: "senha-segura-123")
        ids[:doc_user] = doc_user.id
        Membership.create!(user: doc_user, role: "health_professional", granted_at: Time.current)
        unit = HealthUnit.create!(name: "UBS Trava #{tag}", kind: "ubs")
        ids[:unit] = unit.id
        pro = Professional.create!(user: doc_user, professional_name: "P", council: "CRM", council_state: "PR",
                                   registration_number: tag.to_i(16).to_s[0, 8], cns: Professionals::Cns.generate(tag))
        ids[:pro] = pro.id
        link = Professionals::OpenLink.call(professional: pro, health_unit_id: unit.id, cbo_code: "225125", by: admin)
                                      .payload[:link]
        ids[:link] = link.id
      end
    end
  end

  after do
    2.times { release << true }
    threads.each { |t| t.join(5) || t.kill }
    purge_committed_rows(ids)
  end

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A) { ApplicationRecord.transaction(&) } }

  # A conexão do exemplo (aberta pelo around de city_test_databases.rb) já
  # está em TEST_CITY_A, então basta consultar pg_stat_activity nela: nenhuma
  # das duas threads em disputa é a dona dessa conexão.
  def wait_for_lock_wait(timeout: 5)
    deadline = Time.current + timeout
    loop do
      count = ApplicationRecord.connection.select_value(
        "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'"
      ).to_i
      return true if count.positive?
      return false if Time.current > deadline

      sleep 0.05
    end
  end

  it "o lançamento que espera o encerramento recebe link_ended" do
    locked = Queue.new
    threads << ender = Thread.new do
      in_city do
        link = ProfessionalLink.find(ids[:link])
        link.lock!
        locked << true
        release.pop
        link.update!(ended_at: Time.current, ended_by_user_id: ids[:admin])
      end
    end
    locked.pop(timeout: 5) or raise "a thread não pegou o lock"

    outcome = Queue.new
    threads << scheduler = Thread.new do
      CityConnection.with(TEST_CITY_A) do
        Current.set(city: TEST_CITY_A) do
          start = 2.days.from_now
          outcome << Professionals::ScheduleShift.call(link: ProfessionalLink.find(ids[:link]), starts_at: start,
                                                       ends_at: start + 4.hours, by: User.find(ids[:admin])).reason
        end
      end
    end
    expect(wait_for_lock_wait).to be(true) # o lançamento está esperando o FOR UPDATE do encerramento

    release << true
    ender.join(5)
    expect(outcome.pop(timeout: 5)).to eq(:link_ended)
  end

  it "o encerramento que espera o lançamento em curso cancela o turno futuro recém-lançado" do
    locked = Queue.new
    scheduled = Queue.new
    threads << scheduler = Thread.new do
      in_city do
        start = 2.days.from_now
        result = Professionals::ScheduleShift.call(link: ProfessionalLink.find(ids[:link]), starts_at: start,
                                                   ends_at: start + 4.hours, by: User.find(ids[:admin]))
        scheduled << result
        locked << true
        release.pop
      end
    end
    result = scheduled.pop(timeout: 5) or raise "o lançamento não terminou"
    ids[:shift] = result.payload[:shift].id
    locked.pop(timeout: 5) or raise "a thread não pegou o FOR SHARE"

    outcome = Queue.new
    threads << ender = Thread.new do
      in_city { outcome << Professionals::EndLink.call(link: ProfessionalLink.find(ids[:link]), by: User.find(ids[:admin])) }
    end
    expect(wait_for_lock_wait).to be(true) # o encerramento está esperando o FOR SHARE do lançamento

    release << true
    scheduler.join(5)
    ender.join(5)
    end_result = outcome.pop(timeout: 5)
    expect(end_result.payload[:cancelled_shift_ids]).to eq([ ids[:shift] ])
    expect(ProfessionalShift.find(ids[:shift]))
      .to have_attributes(cancel_reason: ProfessionalShift::LINK_ENDED_REASON, cancelled_at: be_present)
  end
end
