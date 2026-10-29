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

# ADR 0045: o prescritor, o número da notificação, a retenção e as quantidades
# contadas/recebidas da farmácia nunca caem no "Parameters:" do log.
RSpec.describe "filter_parameters da farmácia" do
  it "prescriber, retention, notification_number, counted_quantity e quantity_received viram [FILTERED]; chave parecida passa" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter("prescriber" => { "name" => "Dra. X" }, "retention" => { "notification_number" => "PR-1" },
                             "notification_number" => "PR-2026-000123", "counted_quantity" => "4", "quantity_received" => "3",
                             "quantity" => "5", "location_id" => "abc", "prescribers" => "x")
    expect(filtered).to eq("prescriber" => "[FILTERED]", "retention" => "[FILTERED]", "notification_number" => "[FILTERED]",
                           "counted_quantity" => "[FILTERED]", "quantity_received" => "[FILTERED]",
                           "quantity" => "5", "location_id" => "abc", "prescribers" => "x")
  end
end
