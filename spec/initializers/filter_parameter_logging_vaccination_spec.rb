require "rails_helper"

RSpec.describe "filtro de log do módulo 29" do
  it "filtra as chaves da situação da caderneta e da credencial RNDS" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    keys = %w[series next_dose_code due_on pfx_base64 pfx_password requester_cnes immunobiological_code]
    filtered = filter.filter(keys.index_with { "valor-sensivel" })
    expect(filtered.values.uniq).to eq([ "[FILTERED]" ])
  end
end
