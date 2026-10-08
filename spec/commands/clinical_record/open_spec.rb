require "rails_helper"

# ADR 0031 (spec §5; contratos §3): abertura por CPF, motivo de lista (nota
# de 10+ com other), válida 30 minutos; trilha só com ids e o código do motivo.
RSpec.describe ClinicalRecord::Open do
  before { Current.city = clinical_city!; ciap2_release! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:nurse) { doctor!(unit, cbo: "223505") }
  let(:citizen) { verified_citizen!(1) }
  let!(:patient) { Patients::Resolve.call(citizen).payload[:patient] }

  # CPF digitado com pontuação ("123.456.789-09"). CitizenIdentity::Cpf.mask
  # esconde dígitos ("***.456.789-**") e não serve como entrada.
  def formatted(cpf) = cpf.sub(/\A(\d{3})(\d{3})(\d{3})(\d{2})\z/, '\\1.\\2.\\3-\\4')
  def open(**args) = described_class.call(user: nurse, cpf: formatted(citizen.cpf), reason_code: "case_review", **args)

  it "abre por 30 minutos (CPF com máscara); evento sem a nota" do
    result = open(reason_code: "other", reason_note: "pedido da coordenação MARCADOR-NOTA")
    opening = result.payload[:opening]
    expect(opening).to have_attributes(patient_id: patient.id, user_id: nurse.id, reason_code: "other")
    expect(opening.expires_at - opening.created_at).to eq(30.minutes)
    expect(DomainEvent.where(name: "clinical_record.opened").sole.payload)
      .to eq("opening_id" => opening.id, "patient_id" => patient.id, "user_id" => nurse.id, "reason_code" => "other")
    expect(DomainEvent.pluck(:payload).to_json).not_to include("MARCADOR-NOTA")
  end

  it "nota só com other (e descartada nos demais motivos)" do
    expect(open(reason_note: "não precisava").payload[:opening].reason_note).to be_nil
    { { reason_code: "other" } => :invalid_reason, { reason_code: "other", reason_note: "curta" } => :invalid_reason,
      { reason_code: "other", reason_note: "x" * 501 } => :invalid_reason, { reason_code: "curiosidade" } => :invalid_reason,
      { reason_code: [ "case_review" ] } => :invalid_reason }.each do |args, reason|
      expect(open(**args).reason).to eq(reason), args.inspect
    end
  end

  it "CPF sem paciente (só declarado ou inexistente) → patient_not_found" do
    declared = screening_citizen!(2)
    expect(described_class.call(user: nurse, cpf: declared.cpf, reason_code: "active_search").reason).to eq(:patient_not_found)
    expect(described_class.call(user: nurse, cpf: "lixo", reason_code: "active_search").reason).to eq(:patient_not_found)
    expect(described_class.call(user: nurse, cpf: CitizenIdentity::Cpf.mask(citizen.cpf), reason_code: "active_search").reason)
      .to eq(:patient_not_found) # máscara com asteriscos não identifica ninguém
    expect(ClinicalRecordOpening.count).to eq(0)
  end

  it "recepção, sem vínculo e técnico não abrem" do
    expect(described_class.call(user: reception!, cpf: citizen.cpf, reason_code: "case_review").reason).to eq(:missing_role)
    loose = staff_with("solto-#{SecureRandom.hex(3)}@x.gov.br", "health_professional")
    expect(described_class.call(user: loose, cpf: citizen.cpf, reason_code: "case_review").reason).to eq(:missing_link)
    expect(described_class.call(user: doctor!(unit, cbo: "322205"), cpf: citizen.cpf, reason_code: "case_review").reason)
      .to eq(:cbo_not_allowed)
  end
end
