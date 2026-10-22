# Um registro datado de uma fonte (consulta, sinais, exame, procedimento) —
# só a data, o CBO e os códigos da consulta; nunca valor clínico. `codes` são
# pares [terminologia, código] ("ciap2" | "cid10", como PatientProblem), para o
# filtro casar cada código só com a lista da MESMA terminologia.
module CareLines
  Event = Data.define(:on, :cbo, :codes) do
    def initialize(on:, cbo: nil, codes: []) = super
    def inspect = "#<CareLines::Event on=#{on}>"
    alias_method :to_s, :inspect
    def pretty_print(q) = q.text(inspect)
    # ActiveSupport faz Data#as_json = to_h.as_json: sem isto o to_json/render json vazaria os códigos.
    def as_json(*) = { "on" => on.iso8601, "cbo" => cbo }
  end
end
