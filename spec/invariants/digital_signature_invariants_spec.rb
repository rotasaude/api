# spec/invariants/digital_signature_invariants_spec.rb
require "rails_helper"

# ADR 0032, "Invariantes": cada linha é um exemplo. Esta suíte não traz código
# novo: prova que as tasks anteriores, juntas, seguram o que o ADR promete.
RSpec.describe "Invariantes do ADR 0032" do
  include ActiveJob::TestHelper

  before do
    Current.city = signature_city!
    ciap2_release!; cid10_release!; sigtap_release!
    stub_psc!
    @signer = stub_signer!
  end
  after { Current.reset }

  let(:unit) { create_unit }
  let(:doctor) { signer_doctor!(unit) }
  let(:cpf) { SignatureHelpers::DOCTOR_CPF }

  def consume!(name)
    DomainEvent.where(name: name).order(:occurred_at).each do |event|
      Signatures::RequestJob.perform_now(event_id: event.id, event_name: event.name, city_slug: Current.city.slug, payload: event.payload)
    end
  end

  it "finalizar nunca espera a assinatura: PSC e signer fora do ar; o pedido fica pending com o motivo (Review Focus 3)" do
    certificate = linked_certificate!(doctor, leaf: fake_psc.leaf(cpf))
    signature_session!(doctor, certificate: certificate, token: fake_psc.token_for!(cpf: cpf))
    fake_psc.failures.push(*Array.new(10, 503))
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    expect(consultation.reload).to be_finalized
    consume!("consultation.finalized")
    request = SignatureRequest.sole
    3.times { Signatures::SignJob.perform_now(city_slug: Current.city.slug, request_id: request.id) }
    expect(request.reload).to have_attributes(status: "pending", reason_code: "provider_unavailable", attempts: 3)
  end

  it "assinatura gravada não muda; revogação posterior muda só a validação" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    signature = sign_document!(consultation, author: doctor)
    before = signature.slice(:canonical_sha256, :pdf_sha256, :signed_at)
    @signer.revoked_serials << signature.signer_certificate.serial_number
    Signatures::Verify.call(signature, explicit: true)
    expect(signature.reload.last_verification).to eq("invalid")
    expect(signature.slice(:canonical_sha256, :pdf_sha256, :signed_at)).to eq(before)
    expect { attempt { signature.update!(signed_at: 1.day.ago) } }.to raise_error(ActiveRecord::StatementInvalid, /never changes/)
  end

  it "só o autor assina o próprio documento, com o certificado do próprio CPF" do
    other_unit = create_unit("UBS Dois")
    other = signer_doctor!(other_unit, cpf: SignatureHelpers::OTHER_CPF)
    other_certificate = linked_certificate!(other, leaf: fake_psc.leaf(SignatureHelpers::OTHER_CPF))
    signature_session!(other, certificate: other_certificate, token: fake_psc.token_for!(cpf: SignatureHelpers::OTHER_CPF))
    linked_certificate!(doctor, leaf: fake_psc.leaf(cpf)) # sem sessão
    request = signature_request!(finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1)), author: doctor)

    expect(ApplicationRecord.transaction { Signatures::SignPending.call(request_id: request.id) }).to eq(:pending)
    expect(request.reload.reason_code).to eq("no_session") # a sessão do outro não serve
    token = Signatures::Psc::Token.new(access_token: fake_psc.token_for!(cpf: SignatureHelpers::OTHER_CPF, scope: "multi_signature"),
                                       expires_in: 300, scope: "multi_signature")
    batch = Signatures::RunBatch.call(user: other, request_ids: [ request.id ], token: token)
    expect(batch.payload[:record]).to eq(signed: 0, failed: [])
    expect(Signatures::ReturnToPaper.call(request_id: request.id, by: other, reason: "não é meu documento").reason).to eq(:not_author)
    expect(Signature.count).to eq(0)
  end

  it "nenhum documento é assinado duas vezes" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    signature = sign_document!(consultation, author: doctor)
    expect(Signatures::OpenRequest.call(consultation)).to eq(:exists)
    expect { attempt { signature_row!(signature.signature_request, certificate: signature.signer_certificate) } }
      .to raise_error(ActiveRecord::RecordNotUnique)
    expect(ApplicationRecord.transaction { Signatures::SignPending.call(request_id: signature.signature_request_id) }).to eq(:skipped)
  end

  # Review Focus 3: nada de segredo em log, evento, erro, inspect ou to_s, em
  # todo o caminho: vínculo, sessão, assinatura, lote e verificação.
  it "token, code, code_verifier, state, CPF e texto clínico fora de log, evento, erro, inspect e to_s (vínculo, sessão, assinatura, lote, verificação)" do
    codes = []
    states = []
    # Tudo o que o código devolve/mostra, MENOS os Result de start*: o
    # authorize_url deles é, por desenho, o endereço que o navegador do próprio
    # titular abre (leva state e login_hint=CPF ao PSC); fora de log/evento.
    surfaces = []
    starts = []
    approve = lambda do |url|
      states << URI.decode_www_form(URI(url).query).to_h["state"]
      codes << authorize_and_approve!(url)
      [ states.last, codes.last ]
    end
    log = capture_log do
      link = Signatures::StartLink.call(user: doctor, provider: "vidaas", return_to: "/conta")
      state, code = approve.call(link.payload[:authorize_url])
      starts << link
      linked = Signatures::CompleteOauth.call(user: doctor, state: state, code: code)
      expect(linked).to be_ok
      surfaces << linked

      session = Signatures::StartSession.call(user: doctor, return_to: "/fila")
      state, code = approve.call(session.payload[:authorize_url])
      starts << session
      opened = Signatures::CompleteOauth.call(user: doctor, state: state, code: code)
      expect(opened).to be_ok
      surfaces << opened

      # erro: o mesmo state/code de novo e um state inventado
      surfaces << Signatures::CompleteOauth.call(user: doctor, state: state, code: code)
      surfaces << Signatures::CompleteOauth.call(user: doctor, state: "state-inventado-#{SecureRandom.hex(4)}", code: "code-inventado")

      consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
      request = signature_request!(consultation, author: doctor)
      expect(ApplicationRecord.transaction { Signatures::SignPending.call(request_id: request.id) }).to eq(:signed)
      signature = request.reload.signature

      addendum = Consultations::AddAddendum.call(consultation: consultation, by: doctor, reason: "adendo para o lote aqui",
                                                 text: "Texto do adendo sigiloso").payload[:addendum]
      pending = signature_request!(addendum, author: doctor)
      batch = Signatures::StartBatch.call(user: doctor, request_ids: [ pending.id ], return_to: "/fila")
      expect(batch).to be_ok
      starts << batch
      state, code = approve.call(batch.payload[:authorize_url])
      ran = Signatures::CompleteOauth.call(user: doctor, state: state, code: code)
      expect(ran.payload[:record]).to eq(signed: 1, failed: [])
      surfaces << ran

      surfaces << Signatures::Verify.call(signature, explicit: true)
      surfaces.push(signature, request, SignerCertificate.sole, SignatureSession.last)
      surfaces.push(*SignatureOauthState.all, *Signatures::Providers.for_city(Current.city))
      surfaces.push(Signatures::Psc::Token.new(access_token: fake_psc.issued_tokens.last, expires_in: 300, scope: "multi_signature"))
    end
    verifiers = SignatureOauthState.all.map(&:code_verifier)
    # não vacuidade: sem o que procurar, os "não contém" abaixo passariam à toa
    expect(fake_psc.issued_tokens).not_to be_empty
    expect(codes).not_to be_empty
    expect(verifiers).not_to be_empty
    expect(log).not_to be_empty
    secrets = fake_psc.issued_tokens + codes + states + verifiers +
              [ cpf, FakePsc::App::CLIENT_SECRET, "Refere sede", "Metformina 500", "Diabetes mellitus", "adendo sigiloso" ]
    expect(secrets.compact.select { |secret| log.include?(secret) }).to be_empty

    payloads = DomainEvent.where("name LIKE 'signature.%'").pluck(:payload).map(&:to_json).join
    expect(secrets.compact.select { |secret| payloads.include?(secret) }).to be_empty
    # Start*: a URL leva state, code_challenge e login_hint (por desenho), mas
    # nunca token, code, code_verifier ou segredo do cliente; e o inspect também não.
    starts.each do |start|
      url = start.payload[:authorize_url]
      expect(URI.decode_www_form(URI(url).query).to_h).to include("code_challenge")
      leaks = fake_psc.issued_tokens + codes + verifiers + [ FakePsc::App::CLIENT_SECRET ]
      expect(leaks.select { |secret| [ url, start.inspect, start.pretty_inspect, start.to_s ].any? { |t| t.include?(secret) } }).to be_empty
    end
    errors = surfaces.grep(Result).reject(&:ok?).flat_map { |r| [ r.reason, r.message, r.details ].map(&:to_s) }.join
    expect(secrets.compact.select { |secret| errors.include?(secret) }).to be_empty
    texts = surfaces.flat_map { |object| [ object.inspect, object.pretty_inspect, object.to_s ] }.join
    # o PEM/DER do certificado e o PDF assinado não são segredo de sessão; o
    # que não pode aparecer é o token/code/verifier/state/CPF/texto clínico.
    expect(secrets.compact.select { |secret| texts.include?(secret) }).to be_empty
    allowed = %w[certificate_id user_id provider session_id signature_id request_id document_type document_id reason_code verification]
    expect(DomainEvent.where("name LIKE 'signature.%'").pluck(:payload).flat_map(&:keys).uniq - allowed).to be_empty
  end

  context "nenhuma assinatura simulated em produção (ADR 0032, Revisão)" do
    it "(a) o catálogo de produção não tem signature_psc_mock e set! recusa sem gravar nada" do
      key = Signatures::PscMock::KEY
      expect(Platform::Features::SIMULATION_ENVS).not_to include("production")
      expect(Platform::Features.catalog(env: "production").map(&:key)).not_to include(key)
      expect(Platform::Features.catalog(env: "test").map(&:key)).to include(key)
      before_rows = CityFeature.where(key: key).count
      before_events = PlatformEvent.where(name: "city.feature_changed").count
      expect { Platform::Features.set!(city: Current.city, key: key, enabled: true, maintainer: ledi_maintainer!, env: "production") }
        .to raise_error(Platform::Features::UnknownFeature)
      expect(CityFeature.where(key: key).count).to eq(before_rows)
      expect(PlatformEvent.where(name: "city.feature_changed").count).to eq(before_events)
    end

    it "(b) Providers.for_city em produção nunca devolve simulated, nem com linha órfã e FAKE_PSC_URL" do
      stub_psc_mock! # liga o interruptor (linha em city_features) e define FAKE_PSC_URL
      expect(CityFeature.where(key: Signatures::PscMock::KEY, enabled: true)).to exist
      expect(ENV["FAKE_PSC_URL"]).to be_present
      expect(Signatures::Providers.for_city(Current.city, env: "test").map(&:key)).to eq([ "simulated" ])
      expect(Signatures::Providers.for_city(Current.city, env: "production").map(&:key)).not_to include("simulated")
      expect(Signatures::Providers.find("simulated", city: Current.city, env: "production")).to be_nil
      expect(Signatures::Providers.simulated(env: "production")).to be_nil
    end

    it "(c) assinar com certificado simulated em produção não grava nada e deixa o pedido parado" do
      stub_psc_mock!
      certificate = linked_certificate!(doctor, provider: "simulated", leaf: fake_psc("simulated").leaf(cpf))
      signature_session!(doctor, certificate: certificate, token: fake_psc("simulated").token_for!(cpf: cpf))
      request = signature_request!(finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1)), author: doctor)
      outcome = ApplicationRecord.transaction { Signatures::SignPending.call(request_id: request.id, env: "production") }
      expect(outcome).to eq(:pending)
      expect(request.reload).to have_attributes(status: "pending", reason_code: "provider_unavailable")
      expect(Signature.where(provider: "simulated").count).to eq(0)
      expect(Signature.count).to eq(0)
    end
  end

  it "as tabelas do 19a não mudam" do
    migration = File.read(Dir[Rails.root.join("db/city_migrate/20261008500001_*.rb")].sole)
    tables = /:(consultations|consultation_\w+|patients|patient_\w+|clinical_record_openings|citizens)\b/
    expect(migration.scan(/(?:add_column|remove_column|change_column|change_table|rename_column|add_reference)\s+#{tables}/)).to be_empty
  end
end
