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
        doc_user = User.create!(email_address: "doc-#{tag}@c.gov.br", password: "senha-segura-123")
        Membership.create!(user: doc_user, role: "health_professional", granted_at: Time.current)
        unit = HealthUnit.create!(name: "UBS Trava #{tag}", kind: "ubs")
        pro = Professional.create!(user: doc_user, professional_name: "P", council: "CRM", council_state: "PR",
                                   registration_number: tag.to_i(16).to_s[0, 8], cns: Professionals::Cns.generate(tag))
        link = Professionals::OpenLink.call(professional: pro, health_unit_id: unit.id, cbo_code: "225125", by: admin)
                                      .payload[:link]
        ids.merge!(admin: admin.id, link: link.id, unit: unit.id, pro: pro.id, doc_user: doc_user.id)
      end
    end
  end

  after do
    2.times { release << true }
    threads.each { |t| t.join(5) || t.kill }
    purge_committed_rows(ids)
  end

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A) { ApplicationRecord.transaction(&) } }

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
    expect(scheduler.join(0.5)).to be_nil # esperando o FOR UPDATE

    release << true
    ender.join(5)
    expect(outcome.pop(timeout: 5)).to eq(:link_ended)
  end
end
