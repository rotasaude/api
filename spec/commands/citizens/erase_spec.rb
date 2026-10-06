require "rails_helper"

# ADR 0026 §4.4: a confirmação da exclusão deixa uma casca no lugar do cadastro.
RSpec.describe Citizens::Erase do
  before { Current.city = TEST_CITY_A }

  let(:cpf) { "52998224725" }
  let(:phone) { "+5541998765432" }
  # O WhatsApp grava o telefone como a Meta manda: só dígitos, sem "+".
  let(:whatsapp_phone) { "5541998765432" }

  let(:verifier) { User.create!(email_address: "v-#{SecureRandom.hex(3)}@x.com", password: "secret123") }
  let(:admin) { User.create!(email_address: "a-#{SecureRandom.hex(3)}@x.com", password: "secret123") }
  let!(:pair) { Citizen.create!(cpf: cpf, phone: phone) }
  let!(:triage) { completed_web_triage_for(pair) }
  let(:request) { Citizens::RequestErasure.call(cpf: cpf, document_checked: true, by: verifier).payload[:request] }

  def raw_cpf_of(request)
    ApplicationRecord.connection.select_value(
      ApplicationRecord.sanitize_sql([ "SELECT cpf FROM citizen_erasure_requests WHERE id = ?", request.id ])
    )
  end

  it "deixa a casca: sem CPF, telefone, sessões, códigos nem triagem legível" do
    CitizenSession.create!(phone: phone, token_digest: SecureRandom.hex, expires_at: 1.day.from_now)
    OtpChallenge.create!(phone: phone, code_digest: SecureRandom.hex, expires_at: 10.minutes.from_now)
    InboundMessage.create!(message_id: "wamid.#{SecureRandom.hex(4)}", from: whatsapp_phone, kind: "text",
                           raw: { from: whatsapp_phone, text: "meu cpf é #{cpf}" }.to_json)
    OutboundMessage.create!(to: whatsapp_phone, template: { "name" => "x" }, idempotency_key: SecureRandom.hex, status: 200,
                            response: { contacts: [ { input: whatsapp_phone, wa_id: whatsapp_phone } ] }.to_json)
    OutboundMessage.create!(to: phone, template: { "name" => "y" }, idempotency_key: SecureRandom.hex, status: 200)
    CitizenVerificationCode.create!(citizen: pair, code_digest: SecureRandom.hex, expires_at: 10.minutes.from_now)
    CitizenContactPreference.create!(citizen: pair, sms_opt_in: true)
    recipient!(sent_campaign!, pair)
    # Review Focus 2: conversas do WhatsApp do telefone, sem citizen_id, nos dois formatos.
    centro = Neighborhood.create!(name: "Centro", source: "seed")
    whatsapp = Conversation.create!(phone: phone, state: :greeting)
    whatsapp_digits = Conversation.create!(phone: whatsapp_phone, state: :completed)
    whatsapp_triage = Triage.create!(conversation: whatsapp_digits, protocol_definition: triage.protocol_definition,
                                     protocol_name: triage.protocol_name, status: "completed", tier: "alta",
                                     priority: 1, answers: { "q1" => "sim" }, completed_at: Time.current,
                                     neighborhood: centro)
    pair.update!(neighborhood: centro)
    consent_id = Consent.find_by!(conversation_id: triage.conversation_id).id

    result = described_class.call(request: request, by: admin)

    expect(result.ok?).to be(true)
    expect(result.payload[:request]).to have_attributes(status: "confirmed", decided_by_user_id: admin.id,
                                                        decided_at: be_present)
    pair.reload
    expect(pair.cpf).to start_with("erased:")
    expect(pair.phone).to start_with("erased:")
    expect(pair.cpf).not_to eq(pair.phone)
    expect(pair).to have_attributes(erased_at: be_present, neighborhood_id: nil)
    expect(Citizen.where(cpf: cpf)).to be_empty
    expect(Citizen.where(phone: phone)).to be_empty
    expect(CitizenSession.where(phone: phone)).to be_empty
    expect(OtpChallenge.where(phone: phone)).to be_empty
    expect(InboundMessage.where(from: [ phone, whatsapp_phone ])).to be_empty
    expect(OutboundMessage.where(to: [ phone, whatsapp_phone ])).to be_empty
    expect(CitizenVerificationCode.where(citizen_id: pair.id)).to be_empty
    expect(CitizenContactPreference.where(citizen_id: pair.id)).to be_empty
    expect(CampaignRecipient.where(citizen_id: pair.id)).to be_empty
    expect(Conversation.where(phone: [ phone, whatsapp_phone ])).to be_empty
    expect(whatsapp.reload.phone).to start_with("erased:")
    expect(whatsapp_digits.reload.phone).to start_with("erased:")
    expect(Conversation.find(triage.conversation_id).phone).to start_with("erased:")
    [ triage, whatsapp_triage ].each do |t|
      expect(t.reload).to have_attributes(answers: {}, outcome: nil, tier: nil, priority: nil, current_step: nil,
                                          neighborhood_id: nil, anonymized_at: be_present)
    end
    # O consentimento fica (só acréscimo), revogado, com origem "erasure".
    expect(Consent.find(consent_id).revoked_at).to be_present
    expect(Consent.where(conversation_id: triage.conversation_id, revoked_at: nil)).to be_empty
    expect(DomainEvent.where(name: "consent.revoked").last.payload).to include("origin" => "erasure")
    expect(result.payload[:request].reload.cpf).to start_with("erased:")
    expect(DomainEvent.where(name: "citizen.erased").last.payload).to eq("request_id" => request.id)
  end

  it "o pedido confirmado não guarda o CPF: o cifrado gravado muda (achado a; o banco não exige)" do
    before_raw = raw_cpf_of(request)
    expect(before_raw).to be_present

    described_class.call(request: request, by: admin)

    after_raw = raw_cpf_of(request)
    expect(after_raw).not_to eq(before_raw)
    expect(after_raw).not_to include(cpf)
    expect(CitizenErasureRequest.where(cpf: cpf)).to be_empty
  end

  it "nenhuma tabela da cidade decifra o CPF ou o telefone depois" do
    CitizenSession.create!(phone: phone, token_digest: SecureRandom.hex, expires_at: 1.day.from_now)
    OtpChallenge.create!(phone: phone, code_digest: SecureRandom.hex, expires_at: 10.minutes.from_now)
    InboundMessage.create!(message_id: "wamid.#{SecureRandom.hex(4)}", from: whatsapp_phone, kind: "text",
                           raw: { from: whatsapp_phone, text: cpf }.to_json)
    OutboundMessage.create!(to: phone, template: { "name" => "x" }, idempotency_key: SecureRandom.hex, status: 200)
    Conversation.create!(phone: whatsapp_phone, state: :greeting)

    # Um pedido anterior, RECUSADO, do mesmo CPF: a recusa não pode deixar o CPF
    # achável quando o pedido seguinte for confirmado.
    rejected = Citizens::RequestErasure.call(cpf: cpf, document_checked: true, by: verifier).payload[:request]
    Citizens::RejectErasure.call(request: rejected, reason: "documento com foto não confere", by: admin)
    expect(rejected.reload.status).to eq("rejected")

    described_class.call(request: request, by: admin)

    # Para casar o telefone em qualquer formato (com ou sem +55) e o CPF com ou sem máscara.
    needles = [ cpf, "529.982.247-25", "41998765432" ]

    # 1) Todo atributo cifrado com chave da cidade. A busca por igualdade só
    #    serve aos determinísticos (num não-determinístico o `where` cifra com
    #    IV novo e nunca casa — passaria sem provar nada); por isso, além dela,
    #    decifra-se TODA linha de TODO alvo e procura-se o CPF e o telefone
    #    dentro do valor. Assim entram também os alvos que não guardam CPF nem
    #    telefone por natureza (User#otp_secret/otp_pending_secret, Author#token,
    #    Consent#evidence, Professional#cns/contact_email): a varredura não os
    #    pula, só não acha nada neles.
    CityEncryption::CITY_KEYED_TARGETS.each do |model, attr|
      if model.type_for_attribute(attr).deterministic?
        [ cpf, phone, whatsapp_phone ].each do |value|
          expect(model.where(attr => value).exists?).to be(false), "#{model}.#{attr} casa #{value}"
        end
      end
      model.find_each do |row|
        decrypted = row.public_send(attr).to_s
        needles.each do |needle|
          expect(decrypted).not_to include(needle), "#{model}##{row.id}.#{attr} decifra #{needle}"
        end
      end
    end

    # 2) Todas as colunas de texto da cidade em claro (as cifradas guardam
    #    cifrado e não casam): eventos, jsonb, respostas da Meta, filas.
    connection = ApplicationRecord.connection
    columns = connection.select_rows(<<~SQL)
      SELECT table_name, column_name FROM information_schema.columns
      WHERE table_schema = 'public' AND data_type IN ('text', 'character varying', 'jsonb', 'json')
    SQL
    expect(columns).not_to be_empty
    columns.each do |table, column|
      needles.each do |needle|
        hits = connection.select_value(
          "SELECT count(*) FROM #{connection.quote_table_name(table)} " \
          "WHERE #{connection.quote_column_name(column)}::text LIKE #{connection.quote("%#{needle}%")}"
        )
        expect(hits.to_i).to eq(0), "#{table}.#{column} tem #{needle} em claro"
      end
    end
  end

  it "exclui todos os pares do CPF" do
    other_pair = Citizen.create!(cpf: cpf, phone: "+5541998760000")
    described_class.call(request: request, by: admin)

    expect([ pair.reload, other_pair.reload ]).to all(have_attributes(erased_at: be_present))
    expect(Citizen.where(cpf: cpf)).to be_empty
    expect(Citizen.where(phone: "+5541998760000")).to be_empty
  end

  it "não toca na conversa web de outro cidadão que divide o celular (a família)" do
    sibling = Citizen.create!(cpf: "11144477735", phone: phone)
    sibling_triage = completed_web_triage_for(sibling)

    described_class.call(request: request, by: admin)

    expect(sibling.reload).to have_attributes(cpf: "11144477735", phone: phone, erased_at: nil)
    expect(sibling_triage.reload).to have_attributes(anonymized_at: nil, tier: be_present)
    expect(Conversation.find(sibling_triage.conversation_id).phone).to eq(phone)
    expect(Consent.where(conversation_id: sibling_triage.conversation_id, revoked_at: nil)).to exist
  end

  it "vira retido se o atendimento chegou depois do pedido (Review Focus 3)" do
    request
    Attendance.create!(triage: triage, citizen: pair, health_unit: create_unit, checked_in_by_user: verifier,
                       checked_in_at: Time.current, check_in_method: "code")
    session = CitizenSession.create!(phone: phone, token_digest: SecureRandom.hex, expires_at: 1.day.from_now)
    raw_before = raw_cpf_of(request)

    result = described_class.call(request: request, by: admin)

    expect(result.payload[:request]).to have_attributes(status: "retained", decided_by_user_id: admin.id,
                                                        decided_at: be_present)
    expect(raw_cpf_of(request)).to eq(raw_before)
    expect(pair.reload).to have_attributes(cpf: cpf, phone: phone, erased_at: nil)
    expect(triage.reload).to have_attributes(anonymized_at: nil, tier: be_present)
    expect(Consent.where(conversation_id: triage.conversation_id, revoked_at: nil)).to exist
    expect(CitizenSession.exists?(session.id)).to be(true)
    expect(DomainEvent.where(name: "citizen.erasure_retained").last.payload).to eq("request_id" => request.id)
    expect(DomainEvent.where(name: "citizen.erased")).to be_empty
  end

  it "recusa quem pediu e pedido já decidido (Review Focus 4)" do
    own = described_class.call(request: request, by: verifier)
    expect(own.reason).to eq(:own_request)
    expect(request.reload).to have_attributes(status: "pending", decided_by_user_id: nil)
    expect(pair.reload.cpf).to eq(cpf)

    described_class.call(request: request, by: admin)
    expect(described_class.call(request: request.reload, by: admin).reason).to eq(:not_pending)
  end

  it "o mesmo CPF e celular entrando de novo viram cadastro novo (Review Focus 5)" do
    described_class.call(request: request, by: admin)
    fresh = Citizen.create!(cpf: cpf, phone: phone)
    expect(fresh.id).not_to eq(pair.id)
    expect(Conversation.where(citizen_id: fresh.id)).to be_empty
    expect(Citizens::RequestErasure.pairs_of(cpf).to_a).to eq([ fresh ])
  end

  it "ADR 0027: zera o perfil e apaga todas as sugestões do par" do
    pair.update!(birth_date: "1963-04-02", sex: "female", gender_identity: "cis_woman", profile_source: "declared")
    other_source = completed_triage!(pair, triage.protocol_name)
    TriageSuggestion.create!(citizen: pair, source_triage: triage, protocol_name: "saude-mental")
    TriageSuggestion.create!(citizen: pair, source_triage: other_source, protocol_name: "saude-do-idoso",
                             status: "expired", resolved_at: Time.current)

    expect(described_class.call(request: request, by: admin)).to be_ok
    expect(pair.reload).to have_attributes(birth_date: nil, sex: nil, gender_identity: nil, profile_source: nil)
    expect(TriageSuggestion.where(citizen_id: pair.id)).to be_empty
  end

  # ADR 0028 (spec 2026-10-05 §8): a casca não guarda o CNS do CADSUS, a marca
  # da conferência nem a consulta pendente.
  it "apaga CNS, marca do CADSUS e pendente" do
    pair.update!(cns: "700000000000005", cadsus_checked_at: Time.current, cadsus_pending_cns: "700000000000005",
                 cadsus_pending_session_id: SecureRandom.uuid, cadsus_pending_at: Time.current)

    described_class.call(request: request, by: admin)

    row = ApplicationRecord.connection.select_one(
      ApplicationRecord.sanitize_sql([ "SELECT cns, cadsus_checked_at, cadsus_pending_cns, cadsus_pending_session_id, " \
                                       "cadsus_pending_at FROM citizens WHERE id = ?", pair.id ])
    )
    expect(row.values).to all(be_nil)
  end
end
