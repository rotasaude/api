require "rails_helper"

# A chamada (ClinicalAuthorization, FOR SHARE no vínculo) e o encerramento
# (EndLink, FOR UPDATE) se excluem: o encerramento espera a chamada em curso;
# a chamada que chega depois de um encerramento em curso espera e recebe
# missing_link. Threads reais contra TEST_CITY_A, sem fixture transacional.
RSpec.describe "Vínculo: encerrar × chamar" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let(:ids) { {} }

  before do
    CityConnection.with(TEST_CITY_A) do
      Current.set(city: TEST_CITY_A) do
        tag = SecureRandom.hex(4)
        admin = User.create!(email_address: "adm-#{tag}@c.gov.br", password: "senha-segura-123")
        doctor = User.create!(email_address: "doc-#{tag}@c.gov.br", password: "senha-segura-123")
        Membership.create!(user: doctor, role: "health_professional", granted_at: Time.current)
        unit = HealthUnit.create!(name: "UBS Chamada #{tag}", kind: "ubs")
        pro = Professional.create!(user: doctor, professional_name: "P", council: "CRM", council_state: "PR",
                                   registration_number: tag.to_i(16).to_s[0, 8], cns: Professionals::Cns.generate(tag))
        link = ProfessionalLink.create!(professional: pro, health_unit: unit, cbo_code: "225125",
                                        started_at: Time.current, started_by_user: admin)
        ids.merge!(admin: admin.id, doctor: doctor.id, unit: unit.id, link: link.id)
      end
    end
  end

  after do
    2.times { release << true }
    threads.each { |t| t.join(5) || t.kill }
    purge_committed_rows(ids)
  end

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A) { ApplicationRecord.transaction(&) } }

  it "o encerramento espera a checagem em curso; a checagem seguinte recebe missing_link" do
    checked = Queue.new
    threads << caller_thread = Thread.new do
      in_city do
        checked << Professionals::ClinicalAuthorization.check(user: User.find(ids[:doctor]), health_unit_id: ids[:unit])
        release.pop
      end
    end
    expect(checked.pop(timeout: 5)).to eq(:ok)

    threads << ender = Thread.new do
      in_city do
        link = ProfessionalLink.find(ids[:link])
        link.lock!
        link.update!(ended_at: Time.current, ended_by_user_id: ids[:admin])
      end
    end
    expect(ender.join(0.5)).to be_nil # esperando o FOR SHARE da chamada

    release << true
    caller_thread.join(5)
    expect(ender.join(5)).to be(ender)
    after_end = in_city { Professionals::ClinicalAuthorization.check(user: User.find(ids[:doctor]), health_unit_id: ids[:unit]) }
    expect(after_end).to eq(:missing_link)
  end
end
