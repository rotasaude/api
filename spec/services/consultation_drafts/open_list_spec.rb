require "rails_helper"

# Lista de rascunhos abertos (card rotasaude/api#51): para o admin municipal
# achar o órfão — unidade, autora, se ela ainda tem vínculo na unidade, as
# INICIAIS do paciente e as datas. Nunca texto clínico, itens, nome ou CPF.
RSpec.describe ConsultationDrafts::OpenList do
  include ActiveSupport::Testing::TimeHelpers

  before { Current.city = clinical_city!; ciap2_release!; cid10_release!; sigtap_release! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:admin) { staff_with("admin-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin") }

  def draft!(n, full_name:, by: doctor, at: Time.current)
    travel_to(at) do
      started_consultation!(unit: unit, doctor: by, citizen: verified_citizen!(n, full_name: full_name)).tap do |c|
        saved = Consultations::SaveDraft.call(consultation: c, params: draft_body(subjective: "MARCADOR-S", plan: "MARCADOR-P"), by: by)
        raise "rascunho recusado: #{saved.reason}" if saved.failure?
      end
    end
  end

  it "rascunhos mais antigos primeiro, com autora desvinculada marcada, sem finalizada nem descartada" do
    newer = draft!(1, full_name: "Maria Aparecida da Silva", at: 1.hour.ago)
    colleague = doctor!(unit)
    older = draft!(2, full_name: "José dos Santos", by: colleague, at: 3.hours.ago)
    gone = draft!(3, full_name: "Ana Lima", at: 2.hours.ago)
    finalized_consultation!(unit: unit, doctor: doctor!(unit), citizen: verified_citizen!(4, full_name: "Rita Souza"))
    ProfessionalLink.joins(:professional).where(professionals: { user_id: doctor.id })
                    .find_each { |link| link.update!(ended_at: Time.current, ended_by_user: admin) }
    ConsultationDrafts::Discard.call(consultation_id: gone.id, reason: "rascunho aberto por engano", by: admin)

    list = described_class.call
    expect(list.map { |row| row[:consultation_id] }).to eq([ older.id, newer.id ])
    first, second = list
    expect(first).to eq(
      consultation_id: older.id, attendance_id: older.attendance_id, health_unit: { id: unit.id, name: unit.name },
      author: { user_id: colleague.id, name: Screenings::Json.staff_name(colleague) }, author_linked: true,
      patient_initials: "J.S.", started_at: older.started_at.iso8601, last_saved_at: older.reload.updated_at.iso8601
    )
    expect(second).to include(author_linked: false, patient_initials: "M.A.S.", author: { user_id: doctor.id, name: Screenings::Json.staff_name(doctor) })
  end

  it "vínculo ativo em OUTRA unidade não conta como vinculada" do
    draft!(1, full_name: "Maria Aparecida da Silva")
    ProfessionalLink.joins(:professional).where(professionals: { user_id: doctor.id })
                    .find_each { |link| link.update!(ended_at: Time.current, ended_by_user: admin) }
    link_professional!(doctor, create_unit("UBS Norte"))
    expect(described_class.call.sole[:author_linked]).to eq(false)
  end

  it "o JSON não leva nome, CPF, texto nem itens do rascunho" do
    consultation = draft!(1, full_name: "Maria Aparecida da Silva")
    json = described_class.call.to_json
    citizen = consultation.attendance.citizen
    [ "Maria", "Aparecida", "Silva", citizen.cpf, consultation.patient.cpf, "MARCADOR", "T90", "0202010503", "draft_items" ].each do |forbidden|
      expect(json).not_to include(forbidden), forbidden
    end
  end
end
