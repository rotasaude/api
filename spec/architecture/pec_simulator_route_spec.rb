require "rails_helper"

# Mesmo princípio de maintenance_route_spec.rb: o simulador do PEC assina URL
# com a chave da cidade — só existe em development, e a garantia é o roteador.
RSpec.describe "the PEC simulator is development-only" do
  it "does not exist outside development" do
    expect(Rails.env.development?).to be(false)
    expect { Rails.application.routes.recognize_path("http://pec-sim.localhost/pec-simulator") }
      .to raise_error(ActionController::RoutingError)
  end
end
