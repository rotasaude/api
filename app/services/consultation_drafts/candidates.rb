# Quem pode receber o rascunho órfão (card rotasaude/api#51): os usuários
# ativos para quem Consultations::Authorization.link_for daria :ok na unidade
# do atendimento (papel health_professional, vínculo ativo, CBO do 19a — MIAI
# sem 2232 e 3222), menos a autora atual; ordem por nome. O vínculo escolhido
# é o mesmo do link_for (o primeiro permitido por started_at, id). Leitura sem
# trava: ConsultationDrafts::Reassign confere de novo sob trava.
module ConsultationDrafts
  module Candidates
    module_function

    def call(consultation_id:)
      consultation = ClinicalDocuments::Uuid.valid?(consultation_id) ? Consultation.find_by(id: consultation_id) : nil
      return Result.fail(:not_found) unless consultation
      return Result.fail(:not_draft) unless consultation.draft?

      Result.ok(candidates: list(consultation))
    end

    def list(consultation)
      links = ProfessionalLink.active.where(health_unit_id: consultation.attendance.health_unit_id)
                              .joins(professional: :user).merge(User.where(deactivated_at: nil))
                              .where.not(professionals: { user_id: consultation.author_user_id })
                              .where(professionals: { user_id: Membership.active.where(role: "health_professional").select(:user_id) })
                              .includes(:professional).order(:started_at, :id).to_a
      chosen = links.select { |link| Consultations::Cbos.allowed?(link.cbo_code) }.uniq { |link| link.professional.user_id }
      chosen.map { |link| candidate(link) }.sort_by { |row| [ row[:name].to_s.downcase, row[:user_id] ] }
    end

    def candidate(link)
      professional = link.professional
      { user_id: professional.user_id, name: professional.professional_name, cbo_code: link.cbo_code,
        cbo_title: Professionals::Cbo.find(link.cbo_code)&.title, council: professional.council,
        council_state: professional.council_state, registration_number: professional.registration_number }
    end
    private_class_method :list, :candidate
  end
end
