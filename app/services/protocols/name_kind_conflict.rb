# Recusa do gate que precisa de banco (contrato §14 Q16; módulo 32a): um
# protocolo de urgência nunca usa o nome de um protocolo de outro kind
# (triagem ou acolhimento), nem o contrário. Sem isso, a ativação por nome do
# 18 (índice único de `active` por nome) rebaixaria — ou colidiria com — a
# triagem da cidade ao ativar a urgência. Fica fora de app/protocols/, que é o
# motor puro (como o Protocols::SuggestionTargets); o Protocols::Gate a soma.
module Protocols
  module NameKindConflict
    module_function

    def errors(definition)
      return [] unless definition.is_a?(Hash) && definition["name"].is_a?(String)

      name = definition["name"]
      conflict = if Validation::Urgency.urgency?(definition)
                   ProtocolDefinition.exists?([ "name = ? AND definition->>'kind' IS DISTINCT FROM ?", name,
                                                Validation::Urgency::KIND ])
                 else
                   ProtocolDefinition.urgency_protocols.exists?(name: name)
                 end
      return [] unless conflict

      [ "name_kind_conflict: name '#{name}' is used by a protocol of another kind" ]
    end
  end
end
