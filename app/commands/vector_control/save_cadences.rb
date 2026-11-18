# Troca a lista inteira das cadências (módulo 35a, ADR 0054; contrato §5, §12;
# Q8: corpo `{ items }`). Só a coordenação, com step-up (quem chama confere).
# Cada item `{ neighborhood_id, risk_class, strategic_point, days }`, as quatro
# chaves (bairro nulo = cidade; risco nulo = qualquer):
#   - chave desconhecida ou ausente → invalid_request path `items[i].<chave>`;
#   - bairro que não existe, risco fora de RISK_CLASSES, strategic_point não
#     booleano, ponto estratégico com risco (W-10), days fora de 7–365 →
#     invalid_request path `items[i].<campo>`;
#   - a mesma tripla repetida → invalid_request path `items[i]` (a segunda).
# Só o primeiro erro. A linha que fica com a mesma tripla muda no lugar
# (version + 1 se os dias mudam); a nova nasce; a que saiu da lista é apagada.
# Um advisory lock da transação serializa dois PUTs. Sem evento (§17).
#
# Concorrência otimista (Q35): `expected_digest` é o `digest` da lista que a
# tela leu (GET ou o PUT anterior). Obrigatório, sem default na palavra-chave:
# `nil` → expected_digest_required; fora de 64 hex minúsculos →
# invalid_request, ambos com o path `expected_digest`. A conferência roda
# DEPOIS da trava, a mesma da troca, contra as linhas gravadas: divergiu →
# cadences_changed (409), nada gravado. `digest` é o SHA-256 da forma canônica
# das linhas gravadas (nunca do corpo): JSON de `[bairro, risco, dias, PE]`
# por linha, nulo como null, em ordem de (bairro, risco, dias, PE) com o nulo
# primeiro; sem id, version nem carimbos. Lista vazia = digest de `[]`.
module VectorControl
  module SaveCadences
    KEYS = %w[neighborhood_id risk_class strategic_point days].freeze
    MAX_ITEMS = 1000
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    LOCK = "vector_cadences".freeze
    DIGEST = /\A[0-9a-f]{64}\z/

    module_function

    # -> Result.ok(cadences: [VectorCadence], digest:) | fail(:invalid_request, details: { path: })
    #    | fail(:expected_digest_required, details: { path: "expected_digest" }) | fail(:cadences_changed)
    def call(items:, by:, expected_digest:)
      _ = by
      return Result.fail(:expected_digest_required, details: { path: "expected_digest" }) if expected_digest.nil?
      return invalid("expected_digest") unless expected_digest.is_a?(String) && expected_digest.match?(DIGEST)

      refusal = check(items)
      return refusal if refusal

      wanted = items.to_h { |item| [ key(item), item["days"] ] }
      VectorCadence.transaction(requires_new: true) do
        VectorCadence.connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{VectorCadence.connection.quote(LOCK)}))")
        rows = VectorCadence.lock.to_a
        # Depois da trava: a lista gravada não muda mais até o fim desta transação.
        next Result.fail(:cadences_changed) unless digest(rows) == expected_digest

        existing = rows.index_by { |row| [ row.neighborhood_id, row.risk_class, row.strategic_point ] }
        existing.each { |row_key, row| row.delete unless wanted.key?(row_key) }
        wanted.each do |(neighborhood_id, risk_class, strategic_point), days|
          row = existing[[ neighborhood_id, risk_class, strategic_point ]]
          if row
            row.update!(days: days, version: row.version + 1) if row.days != days
          else
            VectorCadence.create!(neighborhood_id: neighborhood_id, risk_class: risk_class, strategic_point: strategic_point, days: days)
          end
        end
        saved = VectorCadence.all.to_a
        Result.ok(cadences: saved, digest: digest(saved))
      end
    end

    # SHA-256 hex da forma canônica de `rows` (as linhas gravadas; padrão: a
    # lista atual). Quem mostra a lista calcula das mesmas linhas que serializa.
    def digest(rows = VectorCadence.all.to_a)
      tuples = rows.map { |row| [ row.neighborhood_id, row.risk_class, row.days, row.strategic_point ] }
      sorted = tuples.sort_by do |neighborhood_id, risk_class, days, strategic_point|
        [ neighborhood_id.nil? ? 0 : 1, neighborhood_id.to_s, risk_class.nil? ? 0 : 1, risk_class.to_s, days, strategic_point ? 1 : 0 ]
      end
      Digest::SHA256.hexdigest(JSON.generate(sorted))
    end

    def check(items)
      return invalid("items") unless items.is_a?(Array) && items.size <= MAX_ITEMS
      return invalid("items[#{items.index { |item| !item.is_a?(Hash) }}]") unless items.all?(Hash)

      neighborhoods = Neighborhood.where(id: items.filter_map { |item| item["neighborhood_id"] if uuid?(item["neighborhood_id"]) }
                                                    .map(&:downcase)).pluck(:id).to_set
      seen = Set.new
      items.each_with_index do |item, index|
        path = "items[#{index}]"
        unknown = (item.keys - KEYS).first || (KEYS - item.keys).first
        return invalid("#{path}.#{unknown}") if unknown

        neighborhood_id = item["neighborhood_id"]
        unless neighborhood_id.nil? || (uuid?(neighborhood_id) && neighborhoods.include?(neighborhood_id.downcase))
          return invalid("#{path}.neighborhood_id")
        end
        return invalid("#{path}.strategic_point") unless [ true, false ].include?(item["strategic_point"])

        risk = item["risk_class"]
        return invalid("#{path}.risk_class") unless risk.nil? || Catalog::RISK_CLASSES.include?(risk)
        return invalid("#{path}.risk_class") if item["strategic_point"] && !risk.nil?
        return invalid("#{path}.days") unless item["days"].is_a?(Integer) && Catalog::CADENCE_DAYS.cover?(item["days"])
        return invalid(path) unless seen.add?(key(item))
      end
      nil
    end

    def key(item) = [ item["neighborhood_id"]&.downcase, item["risk_class"], item["strategic_point"] ]

    def uuid?(value) = value.is_a?(String) && value.match?(UUID)

    def invalid(path) = Result.fail(:invalid_request, details: { path: path })
  end
end
