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
# contadas/recebidas e o fornecedor da entrada da farmácia nunca caem no
# "Parameters:" do log (lote e fabricante já saem por `items`).
RSpec.describe "filter_parameters da farmácia" do
  it "prescriber, retention, notification_number, counted_quantity, quantity_received e supplier viram [FILTERED]; chave parecida passa" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter("prescriber" => { "name" => "Dra. X" }, "retention" => { "notification_number" => "PR-1" },
                             "notification_number" => "PR-2026-000123", "counted_quantity" => "4", "quantity_received" => "3",
                             "quantity" => "5", "location_id" => "abc", "prescribers" => "x",
                             "document" => { "kind" => "donation", "number" => "DOA-1", "supplier" => "Maria Doadora" },
                             "items" => [ { "lot_number" => "L1", "manufacturer" => "EMS" } ], "supplier_id" => "9")
    expect(filtered).to eq("prescriber" => "[FILTERED]", "retention" => "[FILTERED]", "notification_number" => "[FILTERED]",
                           "counted_quantity" => "[FILTERED]", "quantity_received" => "[FILTERED]",
                           "quantity" => "5", "location_id" => "abc", "prescribers" => "x",
                           "document" => { "kind" => "donation", "number" => "[FILTERED]", "supplier" => "[FILTERED]" },
                           "items" => "[FILTERED]", "supplier_id" => "9")
  end

  # As colunas do prescritor da receita externa: o log do SQL filtra os binds
  # pela lista global (o filter_attributes do modelo só vale para o inspect).
  it "prescriber_name, council, council_state e council_number viram [FILTERED]; chave parecida passa" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter("prescriber_name" => "Dra. X", "council" => "CRM", "council_state" => "PR", "council_number" => "54321",
                             "councils" => "x", "council_id" => "9")
    expect(filtered).to eq("prescriber_name" => "[FILTERED]", "council" => "[FILTERED]", "council_state" => "[FILTERED]",
                           "council_number" => "[FILTERED]", "councils" => "x", "council_id" => "9")
  end
end

# ADR 0046: o corpo de POST /dental/prosthesis_orders (sigtap + patient_id) e os
# demais parâmetros clínicos da saúde bucal nunca caem no "Parameters:" do log.
RSpec.describe "filter_parameters da saúde bucal" do
  it "sigtap, procedure_code, procedures, outcomes, dental_outcomes e oral_health_surveillance viram [FILTERED]; chave parecida passa" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter("consultation_id" => "c1", "patient_id" => "p1", "sigtap" => "0701070129",
                             "procedure_code" => "0307010015", "procedures" => [ { "sigtap" => "x" } ],
                             "outcomes" => [ 1 ], "dental_outcomes" => [ 15 ], "oral_health_surveillance" => [ 3 ],
                             "laboratory_name" => "Lab X", "supplies" => [ 1 ], "dental_consultation_type" => 2,
                             "procedure_id" => "9", "outcome_id" => "8")
    expect(filtered).to eq("consultation_id" => "c1", "patient_id" => "p1", "sigtap" => "[FILTERED]",
                           "procedure_code" => "[FILTERED]", "procedures" => "[FILTERED]", "outcomes" => "[FILTERED]",
                           "dental_outcomes" => "[FILTERED]", "oral_health_surveillance" => "[FILTERED]",
                           "laboratory_name" => "[FILTERED]", "supplies" => "[FILTERED]",
                           "dental_consultation_type" => "[FILTERED]", "procedure_id" => "9", "outcome_id" => "8")
  end
end
