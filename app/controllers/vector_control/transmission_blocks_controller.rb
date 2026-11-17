# /vector_control/transmission_blocks (módulo 35a, ADR 0054; contrato §8,
# §12, §17; Q8, Q9, Q13(9); W-3): o bloqueio de transmissão da coordenação
# (403 missing_role para os outros).
#   - GET /transmission_blocks?status[]=&before= → `{ items, next_before }` de
#     TransmissionBlock, mais recente primeiro; GET /:id → TransmissionBlock;
#   - POST /:id/confirm `{ center_block_id, block_ids }` (step-up), /dismiss
#     `{ reason }`, /close `{}`, /cycles `{ starts_on, ends_on }` e
#     /cases/:case_id/move `{ to_transmission_block_id }` → TransmissionBlock
#     (o do destino no mover); fora do estado → 409 invalid_transition path
#     status (Q9);
#   - GET /:id/cases/:case_id/address (step-up) → CaseAddress, a única
#     resposta do 35a com endereço de pessoa; grava a trilha.
# O caso sai só como doença, data e "caso n": nunca paciente, notificação,
# endereço (fora da rota do endereço) nem coordenada. Chave de corpo
# desconhecida → 422 invalid_request com o path dela.
module VectorControl
  class TransmissionBlocksController < BaseController
    LIMIT = 50

    before_action(only: %i[confirm dismiss close add_cycle move]) { query_only! }
    before_action :coordinator!
    before_action :require_step_up!, only: %i[confirm address]
    before_action :load_block, except: :index
    before_action :load_case, only: %i[move address]

    def index
      return unless query_only!(:status, :before)

      statuses = request.query_parameters["status"]
      statuses = [ statuses ] if statuses.is_a?(String)
      unless statuses.nil? || (statuses.is_a?(Array) && statuses.all? { |status| Catalog::BLOCK_STATUSES.include?(status) })
        return render_refusal("invalid_request", path: "status")
      end

      position = cursor
      return if performed?

      scope = statuses ? TransmissionBlock.where(status: statuses) : TransmissionBlock.all
      rows, next_before = page(scope, :created_at, limit: LIMIT, position: position)
      render json: { items: Json.transmission_blocks(rows), next_before: next_before }
    end

    def show
      return unless query_only!

      render json: Json.transmission_block(@block)
    end

    def confirm
      return unless known_keys!(%w[center_block_id block_ids])

      respond(Blocks::Confirm.call(block: @block, center_block_id: body_param("center_block_id"), block_ids: body_param("block_ids"),
                                   by: Current.user))
    end

    def dismiss
      return unless known_keys!(%w[reason])

      respond(Blocks::Dismiss.call(block: @block, reason: body_param("reason"), by: Current.user))
    end

    def close
      return unless known_keys!([])

      respond(Blocks::Close.call(block: @block, by: Current.user))
    end

    def add_cycle
      return unless known_keys!(%w[starts_on ends_on])

      respond(Blocks::AddCycle.call(block: @block, starts_on: body_param("starts_on"), ends_on: body_param("ends_on"), by: Current.user))
    end

    def move
      return unless known_keys!(%w[to_transmission_block_id])

      respond(Blocks::MoveCase.call(block: @block, block_case: @block_case,
                                    to_transmission_block_id: body_param("to_transmission_block_id"), by: Current.user))
    end

    def address
      return unless query_only!

      result = Blocks::CaseAddress.call(block: @block, block_case: @block_case, by: Current.user)
      return render_failure(result) if result.failure?

      render json: result.payload[:address]
    end

    private

    def load_block
      @block = uuid?(params[:id]) ? TransmissionBlock.find_by(id: params[:id]) : nil
      not_found unless @block
    end

    def load_case
      @block_case = uuid?(params[:case_id]) ? @block.cases.find_by(id: params[:case_id]) : nil
      not_found unless @block_case
    end

    def known_keys!(allowed)
      unknown = (body.keys - allowed).first
      return true unless unknown

      render_refusal("invalid_request", path: unknown)
      false
    end

    def respond(result)
      return render_failure(result) if result.failure?

      render json: Json.transmission_block(result.payload[:block].reload)
    end
  end
end
