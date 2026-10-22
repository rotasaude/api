# Um registro datado de uma fonte (consulta, sinais, exame, procedimento) —
# só a data, o CBO e os códigos da consulta; nunca valor clínico.
module CareLines
  Event = Data.define(:on, :cbo, :codes) do
    def initialize(on:, cbo: nil, codes: []) = super
    def inspect = "#<CareLines::Event on=#{on}>"
    alias_method :to_s, :inspect
    def pretty_print(q) = q.text(inspect)
  end
end
