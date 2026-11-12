require "rails_helper"

# Módulo 33, Task 8 (ADR 0051; contrato §3; §16 U1, Q8, Q46; preflight F-3,
# F-18): o registro único de toda manifestação do canal web. Pela sessão:
# `identified | preserved`, com o cidadão da sessão ou o par declarado
# { cpf, full_name } (criado por Citizens::RegisterPerson, sem consentimento; o
# nome vai a manifestant_name). Com anonymous_web: só a denúncia anônima, sem
# pessoa e sem anexo (Task 9). Qualquer recusa desfaz tudo.
RSpec.describe Ombudsman::Register do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { ombudsman_city! }
  let(:phone) { "+5541998765432" }
  let(:session) { CitizenSession.start!(phone: phone).first }
  let(:citizen) { web_citizen!(phone: phone) }
  let(:text) { "Esperei quatro horas na recepção da UBS sem atendimento." }
  let(:now) { Time.zone.local(2026, 11, 11, 10, 0) }

  def attrs(**over) = { "kind" => "complaint", "identification_mode" => "identified", "body" => text }.merge(over.stringify_keys)
  def register(citizen: self.citizen, citizen_session: session, **over)
    described_class.call(attrs: attrs(**over), channel: "web", citizen: citizen, citizen_session: citizen_session, now: now)
  end

  def path_of(result) = [ result.reason, result.details[:path] ]

  def attachment!(owner: session)
    Ombudsman::Attachments.upload(data: png_base64, content_type: "image/png", filename: "anexo-1.png", citizen_session: owner)
                          .payload.fetch(:attachment)
  end

  def nothing_written!
    expect(OmbudsmanManifestation.count).to eq(0)
    expect(OmbudsmanEvent.count).to eq(0)
    expect(DomainEvent.where(name: "ombudsman.manifestation_received").count).to eq(0)
  end

  it "grava a manifestação recebida com o instante, o ciclo e o protocolo de `now`, o evento e o evento de domínio" do
    result = register(identification_mode: "preserved", body: "  #{text}  ")
    expect(result).to be_ok
    manifestation = result.payload.fetch(:manifestation)
    expect(manifestation.reload).to have_attributes(
      citizen_id: citizen.id, channel: "web", kind: "complaint", identification_mode: "preserved", body: text, state: "received",
      cycle: 1, cycle_started_on: Date.new(2026, 11, 11), received_at: now, created_at: now, created_by_user_id: nil,
      manifestant_name: nil, urgent: false, extended: false, suspended_days: 0
    )
    expect(manifestation.protocol).to match(/\A2026-\d{6}\z/)
    event = manifestation.events.sole
    expect(event).to have_attributes(kind: "received", actor: "citizen", actor_user_id: nil, visible_to_citizen: true,
                                     created_at: now, text: nil, data: {})
    expect(DomainEvent.where(name: "ombudsman.manifestation_received").sole.payload).to eq("manifestation_id" => manifestation.id)
    expect(OmbudsmanNotice.count).to eq(0)
  end

  it "corpo com 19 e 4001 code points (depois do strip) → path body; 20 e 4000 passam" do
    expect(path_of(register(body: "é" * 19))).to eq([ :invalid_request, "body" ])
    expect(path_of(register(body: "  #{'é' * 19}  "))).to eq([ :invalid_request, "body" ])
    expect(path_of(register(body: "x" * 4001))).to eq([ :invalid_request, "body" ])
    expect(path_of(register(body: 12_345_678_901_234_567_890))).to eq([ :invalid_request, "body" ])
    nothing_written!
    expect(register(body: "é" * 20)).to be_ok
    expect(register(body: "x" * 4000)).to be_ok
  end

  it "tipo e modo fora do catálogo → path; anonymous pela sessão → path identification_mode" do
    expect(path_of(register(kind: "elogio"))).to eq([ :invalid_request, "kind" ])
    expect(path_of(register(kind: nil))).to eq([ :invalid_request, "kind" ])
    expect(path_of(register(identification_mode: "secret"))).to eq([ :invalid_request, "identification_mode" ])
    expect(path_of(register(kind: "report", identification_mode: "anonymous"))).to eq([ :invalid_request, "identification_mode" ])
    nothing_written!
  end

  it "unidade inativa, inexistente ou não-uuid → path health_unit_id; ativa (CAPS inclusive) passa" do
    inactive = create_unit("UBS Fechada", active: false)
    [ inactive.id, SecureRandom.uuid, "x", 7 ].each do |bad|
      expect(path_of(register(health_unit_id: bad))).to eq([ :invalid_request, "health_unit_id" ]), "esperava recusa de #{bad.inspect}"
    end
    nothing_written!
    caps = HealthUnit.create!(name: "CAPS Centro", kind: "caps", caps_modality: HealthUnit::CAPS_MODALITIES.first)
    expect(register(health_unit_id: caps.id).payload[:manifestation].referred_health_unit_id).to eq(caps.id)
  end

  it "anexos: quatro → too_many_attachments; de outra sessão → path attachment_ids; nada fica ligado nem consumido" do
    four = Array.new(4) { attachment! }
    expect(register(attachment_ids: four.map(&:id)).reason).to eq(:too_many_attachments)
    foreign = attachment!(owner: CitizenSession.start!(phone: "+5541911112222").first)
    expect(path_of(register(attachment_ids: [ four.first.id, foreign.id ]))).to eq([ :invalid_request, "attachment_ids" ])
    expect(path_of(register(attachment_ids: "x"))).to eq([ :invalid_request, "attachment_ids" ])
    nothing_written!
    expect(OmbudsmanAttachment.where.not(ombudsman_manifestation_id: nil)).to be_empty
    expect(ExamFile.where.not(consumed_at: nil)).to be_empty

    result = register(attachment_ids: four.first(3).map(&:id))
    expect(result).to be_ok
    expect(OmbudsmanAttachment.where(ombudsman_manifestation_id: result.payload[:manifestation].id).count).to eq(3)
  end

  describe "a identificação pela sessão" do
    let(:fresh_phone) { "+5541977776666" }
    let(:fresh_session) { CitizenSession.start!(phone: fresh_phone).first }

    def declared(**over)
      register(citizen: nil, citizen_session: fresh_session, cpf: "111.444.777-35", full_name: "  Maria Declarada  ", **over)
    end

    it "par declarado: nasce por RegisterPerson, sem perfil nem consentimento; o nome vai a manifestant_name" do
      result = declared
      expect(result).to be_ok
      pair = Citizen.find_by!(cpf: "11144477735", phone: fresh_phone)
      expect(pair).to have_attributes(full_name: nil, verification_level: "declared", profile_source: nil, birth_date: nil)
      expect(result.payload[:manifestation]).to have_attributes(citizen_id: pair.id, manifestant_name: "Maria Declarada")
      expect(Consent.count).to eq(0)
      expect(DomainEvent.where(name: "citizen.profile_changed").count).to eq(0)

      expect { declared(cpf: "11144477735") }.not_to change(Citizen, :count)
    end

    it "recusa depois do par: o par declarado também é desfeito" do
      expect(path_of(declared(body: "curto"))).to eq([ :invalid_request, "body" ])
      foreign = attachment!(owner: session)
      expect(path_of(declared(attachment_ids: [ foreign.id ]))).to eq([ :invalid_request, "attachment_ids" ])
      expect(Citizen.where(phone: fresh_phone)).to be_empty
      nothing_written!
    end

    it "CPF inválido → invalid_cpf path cpf; 11º no telefone → too_many_people" do
      expect(path_of(declared(cpf: "111.111.111-11"))).to eq([ :invalid_cpf, "cpf" ])
      expect(path_of(declared(cpf: [ "11144477735" ]))).to eq([ :invalid_cpf, "cpf" ])
      10.times { web_citizen!(phone: fresh_phone) }
      expect(declared.reason).to eq(:too_many_people)
      expect(Citizen.where(phone: fresh_phone).count).to eq(10)
      nothing_written!
    end

    it "as formas: cidadão e cpf → path cpf; nenhum → citizen_id; full_name sem cpf ou fora de 2..120 → full_name" do
      expect(path_of(register(cpf: "11144477735"))).to eq([ :invalid_request, "cpf" ])
      expect(path_of(register(citizen: nil))).to eq([ :invalid_request, "citizen_id" ])
      expect(path_of(register(full_name: "Maria"))).to eq([ :invalid_request, "full_name" ])
      expect(path_of(register(citizen: nil, full_name: "Maria"))).to eq([ :invalid_request, "full_name" ])
      expect(path_of(declared(full_name: nil))).to eq([ :invalid_request, "full_name" ])
      expect(path_of(declared(full_name: " M "))).to eq([ :invalid_request, "full_name" ])
      expect(path_of(declared(full_name: "M" * 121))).to eq([ :invalid_request, "full_name" ])
      expect(declared(full_name: "M" * 120)).to be_ok
    end

    it "cidadão excluído no intervalo (lápide) → not_own_citizen, nada gravado" do
      citizen.update_columns(erased_at: Time.current)
      expect(register.reason).to eq(:not_own_citizen)
      nothing_written!
    end
  end

  describe "anonymous_web (denúncia anônima, Task 9)" do
    def anonymous(**over)
      described_class.call(attrs: { "kind" => "report", "identification_mode" => "anonymous", "body" => text }.merge(over.stringify_keys),
                           channel: "web", anonymous_web: true, now: now)
    end

    it "grava a denúncia sem pessoa, com protocolo e evento recebido" do
      result = anonymous
      expect(result).to be_ok
      expect(result.payload[:manifestation].reload).to have_attributes(kind: "report", identification_mode: "anonymous", citizen_id: nil,
                                                                       manifestant_name: nil, channel: "web", state: "received")
      expect(result.payload[:manifestation].events.sole).to have_attributes(kind: "received", actor: "citizen", visible_to_citizen: true)
    end

    it "outro tipo, outro modo, pessoa ou anexo → path do campo" do
      expect(path_of(anonymous(kind: "praise"))).to eq([ :invalid_request, "kind" ])
      expect(path_of(anonymous(identification_mode: "identified"))).to eq([ :invalid_request, "identification_mode" ])
      expect(path_of(anonymous(cpf: "11144477735"))).to eq([ :invalid_request, "cpf" ])
      expect(path_of(anonymous(full_name: "Maria"))).to eq([ :invalid_request, "full_name" ])
      expect(path_of(anonymous(citizen_id: citizen.id))).to eq([ :invalid_request, "citizen_id" ])
      expect(path_of(anonymous(attachment_ids: [ attachment!.id ]))).to eq([ :invalid_request, "attachment_ids" ])
      nothing_written!
    end
  end

  it "o canal da equipe exige `by:` e não aceita sessão; a sessão é obrigatória fora do anonymous_web; canal desconhecido é erro" do
    expect { described_class.call(attrs: attrs, channel: "phone", citizen: citizen, citizen_session: session) }.to raise_error(ArgumentError)
    expect { described_class.call(attrs: attrs, channel: "phone") }.to raise_error(ArgumentError)
    expect { described_class.call(attrs: attrs, channel: "phone", by: ombudsman_staff!, citizen_session: session) }.to raise_error(ArgumentError)
    expect { described_class.call(attrs: attrs, channel: "fax", by: ombudsman_staff!) }.to raise_error(ArgumentError)
    expect { described_class.call(attrs: attrs, channel: "web", by: ombudsman_staff!, citizen_session: session) }.to raise_error(ArgumentError)
    expect { described_class.call(attrs: attrs, channel: "web", citizen: citizen) }.to raise_error(ArgumentError)
  end

  describe "canal da equipe (`by:`)" do
    let(:staff) { ombudsman_staff! }

    def staff_register(over = {}, **opts)
      described_class.call(attrs: attrs(manifestant_name: "Ana Lima").merge(over.stringify_keys), channel: "in_person", by: staff, now: now, **opts)
    end

    it "grava o criador, o evento da equipe e o prazo; sem sessão nem aviso" do
      result = staff_register
      expect(result).to be_ok
      manifestation = result.payload.fetch(:manifestation).reload
      expect(manifestation).to have_attributes(channel: "in_person", created_by_user_id: staff.id, manifestant_name: "Ana Lima",
                                               cycle_started_on: Date.new(2026, 11, 11), received_at: now)
      expect(manifestation.events.sole).to have_attributes(kind: "received", actor: "staff", actor_user_id: staff.id, visible_to_citizen: true)
      expect(OmbudsmanNotice.count).to eq(0)
    end

    it "liga o anexo do usuário na mesma transação: recusa depois dele desfaz tudo e o arquivo segue livre" do
      attachment = Ombudsman::Attachments.upload(data: png_base64, content_type: "image/png", filename: "a.png", user: staff)
                                         .payload.fetch(:attachment)
      result = staff_register({ attachment_ids: [ attachment.id, SecureRandom.uuid ] })
      expect(result.reason).to eq(:invalid_request)
      expect(attachment.reload.ombudsman_manifestation_id).to be_nil
      expect(attachment.exam_file.reload.consumed_at).to be_nil
      nothing_written!

      expect(staff_register({ attachment_ids: [ attachment.id ] })).to be_ok
      expect(attachment.reload.exam_file.consumed_at).not_to be_nil
    end

    it "cidadão excluído entre a busca e a gravação → invalid_request citizen_id, nada gravado" do
      Citizen.where(id: citizen.id).update_all(erased_at: Time.current)
      result = described_class.call(attrs: attrs(citizen_id: citizen.id), channel: "phone", by: staff, now: now)
      expect(path_of(result)).to eq([ :invalid_request, "citizen_id" ])
      nothing_written!
    end
  end
end
