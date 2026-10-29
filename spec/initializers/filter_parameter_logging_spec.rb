require "rails_helper"

# ADR 0044: o alvo, a cor e o resultado da regulação dizem o que o paciente
# procura e quão grave é; nunca caem no "Parameters:" do log.
RSpec.describe "filter_parameters da regulação" do
  it "target_code, suggested_color, color e result viram [FILTERED]; chave parecida passa" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter("target_code" => "225133", "suggested_color" => "red", "color" => "red", "result" => "missed",
                             "type" => "specialty", "result_id" => "abc", "colors" => "x")
    expect(filtered).to eq("target_code" => "[FILTERED]", "suggested_color" => "[FILTERED]", "color" => "[FILTERED]",
                           "result" => "[FILTERED]", "type" => "specialty", "result_id" => "abc", "colors" => "x")
  end
end
