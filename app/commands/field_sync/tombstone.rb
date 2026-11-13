# Lápide `moved` do download do app de campo (módulo 24b; contrato §1, §9.4, Q9):
# o domicílio ou o cadastro individual do 24a saiu da microárea. Só acréscimo,
# na transação de quem chama (recusa desfaz). `erased` e `out_of_scope` não têm
# produtor no 24b. Só ids: nunca dado do cidadão.
module FieldSync
  module Tombstone
    module_function

    def moved!(entity_type:, entity_id:, micro_area_id:)
      FieldSyncTombstone.create!(entity_type: entity_type, entity_id: entity_id, micro_area_id: micro_area_id, reason: "moved")
    end
  end
end
