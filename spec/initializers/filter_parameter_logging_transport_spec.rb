require "rails_helper"

# ADR 0048: CNH, acompanhante, prestador, endereço, laudo do TFD, recibo,
# empresa, diário de bordo e comprovante nunca caem no "Parameters:" do log.
RSpec.describe "filtro de log do módulo 30" do
  it "filtra as chaves do transporte e do TFD; a chave parecida passa" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    keys = %w[license_number companion document provider_name address exception_note appointment_at report cid10 sigtap_code
              justification companion_reason receipt_number carrier odometer_start odometer_end fuel expenses station filename data]
    expect(filter.filter(keys.index_with { "valor-sensivel" }).values.uniq).to eq([ "[FILTERED]" ])
    expect(filter.filter("destination_id" => "d1", "vehicle_id" => "v1", "trip_id" => "t1", "stop_id" => "s1"))
      .to eq("destination_id" => "d1", "vehicle_id" => "v1", "trip_id" => "t1", "stop_id" => "s1")
  end
end
