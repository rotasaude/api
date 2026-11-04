require "rails_helper"

# ADR 0049: CID, substâncias, PTS, nome do familiar, tema e casos do
# matriciamento, participantes e reavaliação do CAPS nunca caem no
# "Parameters:" do log; motivo, evolução e texto compartilhado já caem em
# `:reason`, `:note` e `:text`.
RSpec.describe "filtro de log do módulo 31" do
  it "filtra as chaves do CAPS; ids e a chave parecida passam" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    keys = %w[cid_main cid_secondary substances needs goals family_name topic participants reassessment shared_cases
              reason notes shared_text]
    expect(filter.filter(keys.index_with { "valor-sensivel" }).values.uniq).to eq([ "[FILTERED]" ])
    expect(filter.filter("enrollment_id" => "e1", "health_unit_id" => "u1", "group_id" => "g1", "month" => "2026-11", "topics" => "x"))
      .to eq("enrollment_id" => "e1", "health_unit_id" => "u1", "group_id" => "g1", "month" => "2026-11", "topics" => "x")
  end
end
