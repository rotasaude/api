require "rails_helper"

# Módulo 31 (Desvio 2): lotação = papel do CAPS (psychosocial_staff ou
# psychosocial_lead) + vínculo ativo no CAPS; o vínculo mais antigo dá o CBO.
RSpec.describe Psychosocial::Access do
  let!(:city) { psychosocial_city! }
  let(:caps) { caps! }
  let(:other) { caps!(modality: "caps_ad") }

  it "lotação = vínculo ativo no CAPS; o mais antigo dá o CBO" do
    user = caps_staff!(caps, cbo: "251510")
    link_professional!(user, caps, cbo: "223505")
    expect(described_class.link(user, caps.id).cbo_code).to eq("251510")
    expect(described_class.link(user, other.id)).to be_nil
    ProfessionalLink.active.where(health_unit_id: caps.id).find_each { |l| l.update!(ended_at: Time.current, ended_by_user: user) }
    expect(described_class.link(user, caps.id)).to be_nil
  end

  it "sem papel do CAPS não há lotação, mesmo com vínculo" do
    doctor = ubs_doctor!(caps)
    expect(described_class.link(doctor, caps.id)).to be_nil
    expect(described_class.staffed_unit_ids(doctor)).to eq([])
  end

  it "papel revogado tira a lotação; a coordenação é lotada como a equipe" do
    staff = caps_staff!(caps)
    Membership.where(user: staff, role: "psychosocial_staff").find_each(&:revoke!)
    expect(described_class.link(staff, caps.id)).to be_nil

    lead = caps_staff!(caps, cbo: "223505", lead: true)
    expect([ described_class.staff?(lead), described_class.lead?(lead) ]).to eq([ true, true ])
    expect(described_class.link(lead, caps.id).cbo_code).to eq("223505")
    expect(described_class.link(lead, other.id)).to be_nil
  end

  it "vínculo numa unidade que não é CAPS não é lotação" do
    staff = caps_staff!(caps)
    ubs = HealthUnit.create!(name: "UBS #{SecureRandom.hex(3)}", kind: "ubs")
    link_professional!(staff, ubs, cbo: "251510")
    expect(described_class.link(staff, ubs.id)).to be_nil
    expect(described_class.staffed_unit_ids(staff)).to eq([ caps.id ])
  end

  it "staffed_unit_ids: só os CAPS ativos de vínculo ativo, sem repetir" do
    staff = caps_staff!(caps)
    link_professional!(staff, caps, cbo: "223505")
    link_professional!(staff, other, cbo: "251510")
    expect(described_class.staffed_unit_ids(staff)).to contain_exactly(caps.id, other.id)
    other.update!(active: false)
    expect(described_class.staffed_unit_ids(staff)).to eq([ caps.id ])
  end

  it "can_read?: registro do CAPS lotado sim, de outro CAPS não" do
    staff = caps_staff!(caps)
    expect(described_class.can_read?(staff, PsychosocialBed.new(health_unit_id: caps.id))).to be(true)
    expect(described_class.can_read?(staff, PsychosocialBed.new(health_unit_id: other.id))).to be(false)
    expect(described_class.can_read?(nil, PsychosocialBed.new(health_unit_id: caps.id))).to be(false)
  end
end

# Desvio 13: toda leitura nominal de detalhe deixa clinical_record.viewed com
# access "psychosocial" e o recurso; só ids.
RSpec.describe Psychosocial::Trail do
  let!(:city) { psychosocial_city! }

  it "publica clinical_record.viewed só com ids, o acesso e o recurso" do
    caps = caps!
    staff = caps_staff!(caps)
    patient = caps_patient!
    expect { described_class.viewed!(patient: patient, user: staff, resource: "enrollment") }
      .to change { DomainEvent.where(name: "clinical_record.viewed").count }.by(1)
    payload = DomainEvent.where(name: "clinical_record.viewed").order(:created_at).last.payload
    expect(payload).to eq("patient_id" => patient.id, "user_id" => staff.id, "access" => "psychosocial", "reason_code" => nil,
                          "resource" => "enrollment")
    expect { described_class.viewed!(patient: patient, user: staff, resource: "anything") }.to raise_error(ArgumentError)
  end
end

# Formas do contrato §2.
RSpec.describe Psychosocial::Json do
  let!(:city) { psychosocial_city! }

  it "patient_ref com CNS mascarado no CAPS e sem ele fora; pro; unidade; leito; sigtap pela competência" do
    caps = caps!(modality: "caps_ad_iii")
    patient = caps_patient!
    expect(described_class.patient_ref(patient)).to eq("patient_id" => patient.id, "name" => patient.display_name,
                                                        "cns_masked" => patient.cns_masked)
    expect(described_class.patient_ref(patient, caps: false)).to eq("patient_id" => patient.id, "name" => patient.display_name)
    expect(described_class.patient_ref(patient).to_s).not_to include(patient.cns)

    staff = caps_staff!(caps, cbo: "223505")
    expect(described_class.pro(staff, "223505")).to eq("user_id" => staff.id, "name" => staff.professional.professional_name,
                                                       "cbo_code" => "223505")
    expect(described_class.unit(caps)).to eq("id" => caps.id, "name" => caps.name, "caps_modality" => "caps_ad_iii",
                                             "night_capable" => true)
    bed = bed!(caps, label: "L9")
    expect(described_class.bed(bed)).to eq("id" => bed.id, "health_unit_id" => caps.id, "label" => "L9", "active" => true)
    competence = Time.zone.today.strftime("%Y%m")
    expect(described_class.sigtap("0301080208", "raas_psi", competence))
      .to eq("code" => "0301080208", "name" => "ATENDIMENTO INDIVIDUAL DE PACIENTE EM CENTRO DE ATENCAO PSICOSSOCIAL",
             "instrument" => "raas_psi")
    expect(described_class.sigtap("0301080208", "raas_psi", Time.zone.today.beginning_of_month)["name"]).to be_present
  end
end

# P12/P25: limites de texto do CAPS; abaixo do mínimo (ou vazio) →
# invalid_request; acima do máximo → too_long; sempre com o path.
RSpec.describe Psychosocial::Catalog do
  it "text_problem: vazio, curto, no limite e longo" do
    range = described_class::REFERRAL_REASON
    expect(range).to eq(10..2000)
    expect(described_class.text_problem(nil, range, "reason")).to eq(error: "invalid_request", path: "reason")
    expect(described_class.text_problem(42, range, "reason")).to eq(error: "invalid_request", path: "reason")
    expect(described_class.text_problem("   curto  ", range, "reason")).to eq(error: "invalid_request", path: "reason")
    expect(described_class.text_problem("a" * 10, range, "reason")).to be_nil
    expect(described_class.text_problem("a" * 2000, range, "reason")).to be_nil
    expect(described_class.text_problem("a" * 2001, range, "reason")).to eq(error: "too_long", path: "reason")
  end

  it "limites do contrato (P12, P25)" do
    expect([ described_class::NOTES, described_class::REFERRAL_REASON, described_class::CANCEL_REASON,
             described_class::SHARED_TEXT, described_class::NEEDS, described_class::GOAL_TEXT, described_class::TOPIC,
             described_class::FAMILY_NAME, described_class::REASON ])
      .to eq([ 1..4000, 10..2000, 10..2000, 10..2000, 1..4000, 1..500, 1..200, 3..120, 10..500 ])
    expect(described_class::PROBLEM_CODES).not_to include("no_actions")
    expect(described_class::WARNING_CODES).to eq(%w[no_actions])
  end
end
