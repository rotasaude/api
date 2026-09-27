require "rails_helper"

# A chamada (ClinicalAuthorization, FOR SHARE no vínculo) e o encerramento
# (EndLink, FOR UPDATE) se excluem, nas duas direções, provadas com threads
# reais contra TEST_CITY_A (sem fixture transacional):
#   1. checagem em curso trava o encerramento — ele espera o FOR SHARE, e só
#      depois que a checagem committa o FOR UPDATE é concedido.
#   2. encerramento em curso trava a checagem seguinte — ela espera o
#      FOR UPDATE, e só depois que o encerramento committa ela roda e vê o
#      vínculo já encerrado (missing_link).
# A espera real é verificada consultando pg_stat_activity (wait_for_lock_wait
# em spec/support/lock_wait.rb), não por join com timeout curto: um join que
# retorna nil por timeout não distingue "está esperando o lock" de "está
# lento por outro motivo".
RSpec.describe "Vínculo: encerrar × checar autorização clínica" do
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

  it "a checagem em curso trava o encerramento; ele só passa depois que ela committa" do
    checked = Queue.new
    threads << caller_thread = Thread.new do
      in_city do
        checked << Professionals::ClinicalAuthorization.check(user: User.find(ids[:doctor]), health_unit_id: ids[:unit])
        release.pop(timeout: 5) or raise "timeout esperando release na checagem"
      end
    end
    expect(checked.pop(timeout: 5) || raise("timeout esperando o resultado da checagem")).to eq(:ok)

    threads << ender = Thread.new do
      in_city { Professionals::EndLink.call(link: ProfessionalLink.find(ids[:link]), by: User.find(ids[:admin])) }
    end
    expect(wait_for_lock_wait).to be(true) # o encerramento espera o FOR SHARE da checagem em curso

    release << true
    caller_thread.join(5) or raise "a checagem não terminou"
    ender.join(5) or raise "o encerramento não terminou"

    after_end = in_city { Professionals::ClinicalAuthorization.check(user: User.find(ids[:doctor]), health_unit_id: ids[:unit]) }
    expect(after_end).to eq(:missing_link)
  end

  it "o encerramento em curso trava a checagem seguinte; ela espera e recebe missing_link" do
    holding = Queue.new
    threads << ender = Thread.new do
      in_city do
        Professionals::EndLink.call(link: ProfessionalLink.find(ids[:link]), by: User.find(ids[:admin]))
        holding << true
        release.pop(timeout: 5) or raise "timeout esperando release no encerramento"
      end
    end
    holding.pop(timeout: 5) or raise "o encerramento não travou a linha do vínculo"

    outcome = Queue.new
    threads << checker = Thread.new do
      in_city { outcome << Professionals::ClinicalAuthorization.check(user: User.find(ids[:doctor]), health_unit_id: ids[:unit]) }
    end
    expect(wait_for_lock_wait).to be(true) # a checagem espera o FOR UPDATE do encerramento em curso

    release << true
    ender.join(5) or raise "o encerramento não terminou"
    checker.join(5) or raise "a checagem não terminou"
    expect(outcome.pop(timeout: 5) || raise("timeout esperando o resultado da checagem")).to eq(:missing_link)
  end
end
