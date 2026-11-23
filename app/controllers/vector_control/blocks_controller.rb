# /vector_control/blocks (módulo 35a, ADR 0054; contrato §2, §12; Q8):
# quarteirões do bairro e vizinhos. Leitura: coordenação, vector_lab e o
# agente de endemias (vínculo 515140 em alguma equipe); escrita só a
# coordenação (403 missing_role). Lista `{ items }` com TODOS os quarteirões de
# um bairro, sem página, na ordem natural do número (Q18); cada item é o
# CityBlock. Sem dado de pessoa: sem
# trilha. Módulo 35b (Q11): abre com o vector_control ou o zoonoses
# utilizável (os quarteirões e os anéis do inquérito da leishmaniose).
module VectorControl
  class BlocksController < BaseController
    # Q11 (35b): abre com o vector_control ou o zoonoses utilizável.
    skip_before_action :require_vector_control!
    before_action :require_vector_supplies!
    before_action(only: %i[create update add_neighbor remove_neighbor]) { query_only! }
    before_action :coordinator!, only: %i[create update add_neighbor remove_neighbor]
    before_action :load_block, only: %i[update add_neighbor remove_neighbor]

    def index
      return unless query_only!(:neighborhood_id)
      return forbid unless reader?

      neighborhood_id = request.query_parameters["neighborhood_id"]
      return render_refusal("invalid_request", path: "neighborhood_id") unless uuid?(neighborhood_id)

      blocks = CityBlock.where(neighborhood_id: neighborhood_id).includes(:neighborhood).natural_number_order
      render json: { items: Json.blocks(blocks.to_a) }
    end

    def create
      result = SaveBlock.call(params: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.block(result.payload[:block]), status: :created
    end

    def update
      result = SaveBlock.call(params: body, by: Current.user, block: @block)
      return render_failure(result) if result.failure?

      render json: Json.block(result.payload[:block])
    end

    def add_neighbor
      unknown = (body.keys - %w[neighbor_block_id]).first
      return render_refusal("invalid_request", path: unknown) if unknown

      neighbor_result(LinkNeighbor.add(block: @block, neighbor_block_id: body_param("neighbor_block_id"), by: Current.user))
    end

    def remove_neighbor
      return render_refusal("invalid_request", path: body.keys.first) if body.any?

      neighbor_result(LinkNeighbor.remove(block: @block, neighbor_block_id: params[:neighbor_id], by: Current.user))
    end

    private

    def reader?
      user = Current.user
      Access.coordinator?(user) || Access.lab?(user) || Access.field_agent_somewhere?(user)
    end

    def load_block
      @block = uuid?(params[:id]) ? CityBlock.includes(:neighborhood).find_by(id: params[:id]) : nil
      not_found unless @block
    end

    def neighbor_result(result)
      return render_failure(result) if result.failure?

      render json: Json.block(result.payload[:block])
    end
  end
end
