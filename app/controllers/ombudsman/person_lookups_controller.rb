# POST /ombudsman/person_lookup { cpf } → { citizen_id, name, cpf_masked } | null
# (ADR 0051; contrato §5; §16 Q6, Q43; preflight F-7). Busca do atendente que
# registra pelo balcão ou telefone: só o par VERIFICADO do CPF, sobre
# Citizen.not_erased (Q58). Sem par verificado → null, e a equipe registra
# com os dados digitados (manifestant_*). Com vários pares verificados do
# mesmo CPF (telefones distintos), o mais antigo. Não cria paciente e não tem
# trilha (não é prontuário, §13). Devolve só o cidadão, nunca nada de
# manifestação. O CPF só do corpo; chave fora de `cpf` → 422; 30 por minuto
# por usuário (429 too_many_requests).
module Ombudsman
  class PersonLookupsController < BaseController
    rate_limit to: 30, within: 1.minute, only: :create, name: "ombudsman_person_lookup",
               by: -> { Current.user.id }, store: RateLimitStore,
               with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }
    before_action :require_staff!

    def create
      return unless query_only!

      unknown = (body.keys - %w[cpf]).first
      return render_refusal(unknown.to_s[0, KEY_PATH_MAX]) if unknown

      cpf = body_param("cpf")
      digits = cpf.is_a?(String) ? CitizenIdentity::Cpf.normalize(cpf) : nil
      return render_refusal("cpf", "invalid_cpf") unless digits

      citizen = Citizen.not_erased.verification_level_verified.where(cpf: digits).order(:created_at, :id).first
      render json: citizen && { citizen_id: citizen.id, name: citizen.display_name, cpf_masked: citizen.cpf_masked }
    end
  end
end
