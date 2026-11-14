# Pedidos de geração do mapa (módulo 24c, ADR 0053; Q19, Q24): quem chama é o
# maintenance. Marcar e enfileirar acontecem juntos, e um pedido repetido
# enquanto a geração roda não enfileira de novo.
module FieldMaps
  module Request
    module_function

    # -> FieldMap (em `building`). O arquivo publicado, se houver, segue servido (Q30).
    def build!(city)
      FieldMap.transaction do
        map = FieldMap.lock.find_by(city_id: city.id) || FieldMap.new(city_id: city.id)
        next map if map.persisted? && map.state == "building"

        map.update!(state: "building", error_code: nil, requested_at: Time.current)
        BuildJob.perform_later(city.id)
        map
      end
    end

    # -> true se enfileirou; false com uma cópia já em curso.
    def refresh_base!
      return false if FieldMapBase.exists?(state: "copying")

      RefreshBaseJob.perform_later
      true
    end
  end
end
