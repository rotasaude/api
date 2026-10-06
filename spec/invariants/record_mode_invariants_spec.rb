# spec/invariants/record_mode_invariants_spec.rb
require "rails_helper"
require "webmock/rspec"
require Rails.root.join("lib/sigtap_sample").to_s

# Módulo 16, critério de fechamento (ADR 0028, "Invariantes"). Cada bloco tem a
# mutação que precisa deixá-lo vermelho. Os invariantes da fila e do envio
# (ficha não sai desligada; payload aceito apagado) entram aqui pelo plano do
# exportador.
RSpec.describe "Invariantes do modo de prontuário (ADR 0028)", type: :request do
  before { Current.city = TEST_CITY_A; Rails.cache.clear }
  after { Current.reset }

  let(:city) { City.find_by!(slug: TEST_CITY_A.slug) }
  let(:admin) do
    staff_with("admin@cidade.gov.br", "municipal_admin").tap do |u|
      Mfa::Enroll.call(u)
      u.update!(otp_enabled: true)
    end
  end
  let(:verifier) { staff_with("atendente@cidade.gov.br", "citizen_verifier") }
  let(:maintainer) do
    Maintainer.create!(email_address: "inv-#{SecureRandom.hex(3)}@rotasaude.app", password: "s3nha-forte-1",
                       otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  end
  let(:marker) { "senha-marcador-#{SecureRandom.hex(4)}" }
  def json = JSON.parse(response.body)
  def sql(statement) = PlatformRecord.transaction(requires_new: true) { PlatformRecord.connection.execute(statement) }

  # Mutação: tirar `require_feature "cadsus_lookup"` do AttendanceController.
  it "interruptor desligado: a rota da funcionalidade responde 403 e o serviço não é chamado" do
    IntegrationCredential.create!(kind: "cadsus", secret: { "username" => "u", "password" => "p" }, set_by_user: admin,
                                  set_at: Time.current)
    Platform::Features.set!(city: city, key: "cadsus_lookup", enabled: true, maintainer: maintainer)
    Platform::Features.set!(city: city, key: "cadsus_lookup", enabled: false, maintainer: maintainer)
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432")
    expect(Cadsus::Client).not_to receive(:for)
    sign_in_as(verifier)
    json_post "/attendance/cadsus_lookup", cpf: citizen.cpf, code: issue_code_for(citizen)
    expect([ response.status, json["error"] ]).to eq([ 403, "feature_disabled" ])
  end

  # Mutação: devolver `secret` em credential_json, ou tirar :passw do filtro.
  it "nenhuma resposta, evento, auditoria, fila ou log carrega a credencial" do
    city.update!(pec_url: "https://pec.cidade.gov.br")
    stub_request(:post, "https://pec.cidade.gov.br/api/recebimento/login").to_return(status: 500, body: marker)
    sign_in_as(admin).update!(mfa_verified_at: Time.current)
    bodies = []
    # R9: o log de verdade — um logger em debug junto do Rails.logger. cpf/cns vão nos
    # parâmetros só para provar o filtro; a credencial real é o marcador.
    log = StringIO.new
    capture = ActiveSupport::Logger.new(log).tap { |l| l.level = Logger::DEBUG }
    Rails.logger.broadcast_to(capture)
    put "/integrations/credentials/ledi", params: { username: "rota", password: marker, cpf: "52998224725", cns: "700000000000005" }, as: :json
    bodies << response.body
    post "/integrations/credentials/ledi/check", as: :json
    bodies << response.body
    get "/integrations"
    bodies << response.body

    Rails.logger.stop_broadcasting_to(capture)
    expect(log.string).to include("Parameters")
    expect(log.string).not_to include(marker, "52998224725", "700000000000005")
    expect(bodies.join).not_to include(marker)
    expect(DomainEvent.pluck(:payload).to_json).not_to include(marker)
    expect(PlatformEvent.pluck(:payload).to_json).not_to include(marker)
    expect(ActiveJob::Base.queue_adapter.enqueued_jobs.to_json).not_to include(marker)
    expect(IntegrationCredential.find_by!(kind: "ledi").last_check_message).not_to include(marker)
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
                                             .filter("password" => marker, "secret" => marker, "cpf" => marker, "cns" => marker)
    expect(filtered.values).to all(eq("[FILTERED]"))
  end

  # Mutação: CheckConnection ler a credencial ou o PEC de outra cidade (ex.: sem
  # CityConnection, ou Platform::Features.settings de outra City).
  it "a cidade A nunca usa a credencial nem o PEC da cidade B" do
    city.update!(pec_url: "https://pec-a.cidade.gov.br")
    city_b = City.find_by(slug: TEST_CITY_B.slug) ||
             City.create!(slug: TEST_CITY_B.slug, name: TEST_CITY_B.name, status: "active",
                          database_url: TEST_CITY_B.database_url, encryption_key: TEST_CITY_B.encryption_key,
                          schema_version: CitySchema.expected_version.to_s)
    city_b.update!(pec_url: "https://pec-b.cidade.gov.br")
    within_city(city_b) do
      user_b = User.create!(email_address: "admin-b@cidade.gov.br", password: "senha-segura-123")
      IntegrationCredential.create!(kind: "ledi", secret: { "username" => "b", "password" => "senha-de-b" },
                                    set_by_user: user_b, set_at: Time.current)
      IntegrationCredential.create!(kind: "cadsus", secret: { "username" => "b", "password" => "senha-de-b" },
                                    set_by_user: user_b, set_at: Time.current)
    end
    stub_request(:post, %r{\Ahttps://pec-[ab]\.cidade\.gov\.br/}).to_return(status: 200, headers: { "Set-Cookie" => "JSESSIONID=z" })

    expect(Integrations::CheckConnection.call(kind: "ledi", city: city).reason).to eq(:credential_missing)
    expect { Cadsus::Client.for(city) }.to raise_error(Cadsus::Unavailable)

    IntegrationCredential.create!(kind: "ledi", secret: { "username" => "a", "password" => "senha-de-a" }, set_by_user: admin,
                                  set_at: Time.current)
    Integrations::CheckConnection.call(kind: "ledi", city: city)
    within_city(city_b) { Integrations::CheckConnection.call(kind: "ledi", city: city_b) }

    expect(a_request(:post, "https://pec-a.cidade.gov.br/api/recebimento/login").with(body: /senha-de-a/)).to have_been_made.once
    expect(a_request(:post, "https://pec-b.cidade.gov.br/api/recebimento/login").with(body: /senha-de-b/)).to have_been_made.once
    expect(a_request(:post, %r{pec-a}).with(body: /senha-de-b/)).not_to have_been_made
    expect(a_request(:post, %r{pec-b}).with(body: /senha-de-a/)).not_to have_been_made
  end

  # Mutação: tirar terminology_releases_guard de db/platform_triggers.sql.
  it "release de terminologia ativa nunca muda; release com falha nunca fica ativa" do
    dir = SigtapSample.write_to(Dir.mktmpdir, competence: "202610")
    active = Terminology::Import.call(kind: "sigtap", version: "202610", path: dir).payload[:release]
    expect { sql("UPDATE terminology_releases SET source_sha256 = 'x' WHERE id = '#{active.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid)
    expect { sql("UPDATE sigtap_procedures SET name = 'x' WHERE release_id = '#{active.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid)
    dir.join("tb_procedimento.txt").binwrite("lixo\r\n")
    Terminology::Import.call(kind: "sigtap", version: "202611", path: dir)
    failed = TerminologyRelease.find_by!(version: "202611")
    expect(failed.status).to eq("failed")
    expect { sql("UPDATE terminology_releases SET status = 'active' WHERE id = '#{failed.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid)
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  # Mutação: Cnes::Import ou GET /cnes chamar Cnes::Apply.
  it "nenhum casamento do CNES é aplicado sem confirmação da cidade" do
    cnes_city!
    unit = create_unit("UBS Jardim das Flores")
    Cnes::Import.call(competence: "202609", path: Rails.root.join("spec/fixtures/cnes/202609"))
    sign_in_as(admin)
    get "/cnes"
    expect(json["proposals"]).not_to be_empty
    expect(unit.reload.cnes).to be_nil
    expect([ HealthTeam.count, HealthTeamMember.count ]).to eq([ 0, 0 ])
  end

  # Mutação: gravar birth_date/sex do CADSUS, ou o CNS antes da confirmação.
  it "do CADSUS só ficam o CNS e a marca da conferência" do
    IntegrationCredential.create!(kind: "cadsus", secret: { "username" => "u", "password" => "p" }, set_by_user: admin,
                                  set_at: Time.current)
    Platform::Features.set!(city: city, key: "cadsus_lookup", enabled: true, maintainer: maintainer)
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432")
    found = Cadsus::Simulated.new(username: "u").lookup(citizen.cpf)
    sign_in_as(verifier)
    code = issue_code_for(citizen)
    raw_row = lambda do # coluna crua: birth_date/sex são cifrados, então a prova é a coluna vazia, não texto
      ApplicationRecord.connection.select_one(ApplicationRecord.sanitize_sql([ "SELECT * FROM citizens WHERE id = ?", citizen.id ]))
                       .slice("birth_date", "sex")
    end
    json_post "/attendance/cadsus_lookup", cpf: citizen.cpf, code: code
    # Logo após a consulta (antes da verificação, que grava o perfil declarado): nascimento
    # e sexo do CADSUS nunca ficam gravados, e o CNS ainda não foi efetivado.
    expect(raw_row.call).to eq("birth_date" => nil, "sex" => nil)
    expect(citizen.reload.cns).to be_nil

    # Perfil declarado diferente do CADSUS, para o raw não confundir um com o outro.
    json_post "/attendance/verifications", cpf: citizen.cpf, code: code, document_checked: true, cadsus_confirmed: true,
                                           birth_date: (found.birth_date + 1).iso8601, sex: found.sex == "female" ? "male" : "female"
    expect(response).to have_http_status(:created)

    citizen.reload
    expect(citizen.cns).to eq(found.cns)
    expect(citizen.cadsus_checked_at).to be_present
    expect(Citizen.column_names.grep(/cadsus|cns/)).to match_array(%w[cns cadsus_checked_at cadsus_pending_cns
                                                                      cadsus_pending_session_id cadsus_pending_at])
    expect(citizen.birth_date).to eq((found.birth_date + 1).iso8601) # o declarado, nunca o do CADSUS
  end
end
