# Cria ou edita o quarteirão (módulo 35a, ADR 0054; contrato §2). Só a
# coordenação (quem chama confere). Criar: `{ neighborhood_id, number }` com
# bairro ativo; editar: `{ number?, active? }` (o bairro não muda). Número no
# formato BLOCK_NUMBER (senão 422 invalid_request, path number) e único sem
# caixa no bairro (422 block_number_taken, path number). Desativar com imóvel
# ativo no perfil → 409 block_in_use. O quarteirão travado decide a corrida;
# cada escrita sobe version e publica city_block.changed (só ids). Devolve
# ok(block:).
module VectorControl
  module SaveBlock
    CREATE_KEYS = %w[neighborhood_id number].freeze
    UPDATE_KEYS = %w[number active].freeze
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    module_function

    def call(params:, by:, block: nil)
      params = params.to_h.stringify_keys
      invalid = check(params, block)
      return invalid if invalid

      CityBlock.transaction(requires_new: true) do
        result = block ? update(block, params) : create(params, by)
        next result if result.failure?

        DomainEvents.publish("city_block.changed", city_block_id: result.payload[:block].id, user_id: by.id) if result.payload[:changed]
        Result.ok(block: result.payload[:block])
      end
    rescue ActiveRecord::RecordNotUnique => e
      raise unless e.message.include?("idx_city_blocks_number")

      taken
    end

    def check(params, block)
      allowed = block ? UPDATE_KEYS : CREATE_KEYS
      unknown = (params.keys - allowed).first
      return invalid(unknown) if unknown
      return invalid(nil) if block && params.empty?

      unless block
        id = params["neighborhood_id"]
        return invalid("neighborhood_id") unless id.is_a?(String) && id.match?(UUID) && Neighborhood.active_neighborhoods.exists?(id: id)
      end
      return invalid("number") if (!block || params.key?("number")) && !number?(params["number"])
      return invalid("active") if params.key?("active") && ![ true, false ].include?(params["active"])

      nil
    end

    def create(params, by)
      return taken if number_taken?(params["neighborhood_id"], params["number"])

      block = CityBlock.create!(neighborhood_id: params["neighborhood_id"], number: params["number"], created_by_user: by)
      Result.ok(block: block, changed: true)
    end

    def update(block, params)
      block.lock!
      number = params.fetch("number", block.number)
      active = params.fetch("active", block.active)
      return taken if number != block.number && number_taken?(block.neighborhood_id, number, except: block.id)
      return Result.fail(:block_in_use) if block.active && !active && in_use?(block)
      return Result.ok(block: block, changed: false) if number == block.number && active == block.active

      block.update!(number: number, active: active, version: block.version + 1)
      Result.ok(block: block, changed: true)
    end

    def number?(value) = value.is_a?(String) && value.match?(Catalog::BLOCK_NUMBER)

    def number_taken?(neighborhood_id, number, except: nil)
      CityBlock.where(neighborhood_id: neighborhood_id).where("lower(number) = lower(?)", number).where.not(id: except).exists?
    end

    def in_use?(block) = Json.households_counts([ block.id ]).fetch(block.id, 0).positive?

    def taken = Result.fail(:block_number_taken, details: { path: "number" })

    def invalid(path) = Result.fail(:invalid_request, details: path ? { path: path } : {})
  end
end
