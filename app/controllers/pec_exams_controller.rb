# "Solicitar exames" pela ponte do PEC (ADR 0036; contrato §8 com A8/D8). Mesmo
# host, cabeçalhos e página de recusa da página do PEC (herda de
# PecTimelinesController); sem sessão do Rota Saúde: o token da sessão curta
# do módulo 20 vem no corpo do formulário (faz as vezes de CSRF) e é relido a
# cada passo (vínculo, interruptores, pares). Nunca se confia no Referer (o
# PEC manda só a origem, strict-origin). O pedido nasce com origem pec, o
# profissional da chamada assinada como solicitante e o paciente do par
# validado (Patients::Resolve), tudo numa transação.
class PecExamsController < PecTimelinesController
  rate_limit to: 120, within: 1.minute, only: %i[form create], name: "pec_exams", by: -> { request.remote_ip },
             store: RateLimitStore, with: -> { failure("too_many_requests", status: :too_many_requests) }
  before_action :resume_grant

  def form = render_form

  def create
    opened = nil
    ApplicationRecord.transaction do
      citizen = Citizen.not_erased.where(id: @grant.person.citizen_ids).order(:created_at, :id).first
      resolved = citizen ? Patients::Resolve.call(citizen) : Result.fail(:citizen_not_verified)
      opened = if resolved.failure?
                 Result.fail(:pec_citizen_not_verified)
               else
                 Exams::Open.call(patient: resolved.payload[:patient], sigtap_code: params[:sigtap_code].to_s,
                                  priority: priority, unit: @grant.unit,
                                  origin: "pec", requester_user: @grant.user, created_by: @grant.user)
               end
      raise ActiveRecord::Rollback if opened.failure?
    end
    return render_form(error: opened.reason.to_s, status: :unprocessable_entity) if opened.failure?

    order = opened.payload[:order]
    render_form(notice: "Pedido registrado: #{Exams::Labels.exam(order.sigtap_code, order.sigtap_competence)} — guia #{order.short_code}")
  end

  private

  def priority = params[:priority].is_a?(String) && params[:priority].present? ? params[:priority] : "routine"

  def resume_grant
    token = params[:token]
    @grant = token.is_a?(String) ? PecExternal::ViewSession.resume(token, city: Current.city) : nil
    return failure("pec_session_expired", status: :unauthorized) unless @grant

    failure("pec_exam_bridge_disabled") unless Exams::Gate.pec_usable?(Current.city)
  end

  def render_form(notice: nil, error: nil, status: :ok)
    items = ExamCatalogItem.where(active: true).order(:sigtap_code).map do |item|
      { code: item.sigtap_code, label: Exams::AdminJson.label(item.sigtap_code) }
    end
    html(PecExternal::ExamPage.form(display_name: @grant.person.display_name, items: items, token: params[:token], nonce: @nonce,
                                    notice: notice, error: error),
         status: status, form_action: "'self'")
  end
end
