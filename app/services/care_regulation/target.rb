# Alvo regulável (ADR 0044): especialidade (CBO 2002) ou procedimento SIGTAP.
# `group`: medical | dental | procedure. `name` é o nome mostrado em todo
# lugar (rota targets, pedido, fila, guia): na especialidade é o `label` do
# YAML ("Cardiologia", G12 #6); no procedimento, o nome da SIGTAP. Não leva
# dado de paciente.
module CareRegulation
  Target = Data.define(:type, :code, :name, :group, :label) do
    def to_json_hash = { code: code, name: name }
  end
end
