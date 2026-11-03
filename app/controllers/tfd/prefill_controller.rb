# GET /tfd/prefill?consultation_id= (contrato §6): o botão "pedir TFD" da
# consulta (19a). Só o médico 225* autor da consulta (não descartada; outra →
# 404). `cid10` = o primeiro problema CID-10 registrado na consulta;
# `sigtap_code` = o alvo do primeiro pedido de regulação de procedimento da
# consulta; senão nulos. Sem trilha: a consulta já deixa a dela.
module Tfd
  class PrefillController < BaseController
    def show
      return unless require_physician!
      return unless query_only!("consultation_id")

      id = request.query_parameters["consultation_id"]
      consultation = uuid?(id) ? Consultation.where.not(status: "discarded").find_by(id: id, author_user_id: Current.user.id) : nil
      return not_found unless consultation

      cid10 = ConsultationProblem.where(consultation_id: consultation.id, terminology: "cid10").order(:created_at, :id).pick(:code)
      sigtap = RegulationRequest.where(consultation_id: consultation.id, target_type: "procedure").order(:created_at, :id).pick(:target_code)
      render json: { patient_id: consultation.patient_id, cid10: cid10, sigtap_code: sigtap }
    end
  end
end
