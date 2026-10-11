require "rails_helper"

# Candidatos à designação (card rotasaude/api#51): quem pode registrar consulta
# na unidade do atendimento pela regra do 19a (papel, vínculo ativo, CBO do
# MIAI sem 2232/3222), menos a autora atual; com CBO e conselho.
RSpec.describe ConsultationDrafts::Candidates do
  before { Current.city = clinical_city!; ciap2_release!; cid10_release!; sigtap_release! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:admin) { staff_with("admin-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin") }
  let(:consultation) { started_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1)) }

  it "elegíveis da unidade por nome, com CBO e conselho; fora a autora, dentista, técnico, encerrado, outra unidade" do
    consultation
    nurse = doctor!(unit, cbo: "223505").tap { |u| u.professional.update!(professional_name: "Beatriz Enfermeira", council: "COREN", registration_number: "123456") }
    colleague = doctor!(unit).tap { |u| u.professional.update!(professional_name: "Alberto Médico") }
    doctor!(unit, cbo: "223208")
    doctor!(unit, cbo: "322205")
    doctor!(unit).tap { |u| ProfessionalLink.joins(:professional).where(professionals: { user_id: u.id }).find_each { |l| l.update!(ended_at: Time.current, ended_by_user: admin) } }
    doctor!(create_unit("UBS Norte"))
    staff_with("sem-papel-#{SecureRandom.hex(3)}@cidade.gov.br", "citizen_verifier").tap { |u| link_professional!(u, unit) }
    doctor!(unit).tap { |u| u.update!(deactivated_at: Time.current) }

    result = described_class.call(consultation_id: consultation.id)
    expect(result).to be_ok
    expect(result.payload[:candidates]).to eq([
      { user_id: colleague.id, name: "Alberto Médico", cbo_code: "225125", cbo_title: "Médico clínico", council: "CRM",
        council_state: "PR", registration_number: colleague.professional.registration_number },
      { user_id: nurse.id, name: "Beatriz Enfermeira", cbo_code: "223505", cbo_title: "Enfermeiro", council: "COREN",
        council_state: "PR", registration_number: "123456" }
    ])
  end

  it "inexistente → not_found; finalizada ou descartada → not_draft" do
    expect(described_class.call(consultation_id: SecureRandom.uuid).reason).to eq(:not_found)
    expect(described_class.call(consultation_id: "lixo").reason).to eq(:not_found)
    finalized = finalized_consultation!(unit: unit, doctor: doctor!(unit), citizen: verified_citizen!(2, full_name: "Rita Souza"))
    expect(described_class.call(consultation_id: finalized.id).reason).to eq(:not_draft)
    ConsultationDrafts::Discard.call(consultation_id: consultation.id, reason: "rascunho aberto por engano", by: admin)
    expect(described_class.call(consultation_id: consultation.id).reason).to eq(:not_draft)
  end
end
