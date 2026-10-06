# O pedido que a triagem gerou (ou no qual foi fundida), para o resultado do
# cidadão (contratos §5). Só pedido vivo (open/scheduled): o encerrado
# (atendido, cancelado, movido, consentimento revogado ou cadastro excluído)
# devolve nil, e o status exposto é sempre "open" ou "scheduled". O movido de
# unidade (api#29) é seguido pela cópia, que leva origin_triage_id e as
# ligações. scheduled_at é a hora do horário vivo (Appointment::LIVE), com
# fuso; nil sem horário vivo.
module Scheduling
  module TriageRequest
    module_function

    def for(triage, catalog: AppointmentTypes.catalog)
      linked = AppointmentRequestTriage.where(triage_id: triage.id).select(:request_id)
      base = AppointmentRequest.live_requests
      request = base.where(origin_triage_id: triage.id).or(base.where(id: linked))
                    .includes(:target_unit).order(created_at: :desc, id: :desc).first
      return nil unless request

      live = request.appointments.live.order(created_at: :desc).first
      { unit_name: request.target_unit&.name, due_on: request.due_on.iso8601,
        appointment_type_name: catalog.name_for(request.appointment_type_key),
        status: request.status, scheduled_at: live&.scheduled_at&.iso8601 }
    end
  end
end
