# GET /psychosocial/patients/:id/link (ADR 0049; contrato §7, P10, P27): o
# vínculo do paciente com o CAPS visto pela UBS (Psychosocial::Link). Lê quem
# já pode abrir o paciente pela leitura contextual do ADR 0031
# (ClinicalRecord::Access): sem health_professional → 403 missing_role; fora
# de contexto e sem abertura justificada → 403 out_of_context. Não exige
# lotação no CAPS (quem lê é a UBS). Trilha `clinical_record.viewed`
# (`resource: "link_shared_cases"`) só quando há caso compartilhado; o resto
# não é texto clínico. Id na URL; nada na query.
module Psychosocial
  class LinksController < BaseController
    def show
      return unless query_only!
      return forbid unless Current.user.has_role?("health_professional")

      patient = uuid?(params[:id]) ? Patient.find_by(id: params[:id].downcase) : nil
      return not_found unless patient

      grant = ClinicalRecord::Access.call(user: Current.user, patient: patient)
      return forbid(grant.reason.to_s) unless grant.allowed?

      link = Link.for(patient: patient, viewer: Current.user)
      Trail.viewed!(patient: patient, user: Current.user, resource: "link_shared_cases") if link["shared_cases"].present?
      render json: link
    end
  end
end
