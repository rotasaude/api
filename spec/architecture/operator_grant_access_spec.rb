require "rails_helper"

# Operador dentro da cidade é só leitura (Plano 3B). A negação é por padrão, e
# esta guarda fixa QUEM libera: só a API de leitura da cidade e a própria sessão.
# Um controller novo que chame allow_operator_grant_access precisa passar por aqui.
RSpec.describe "Operator grant access allowlist" do
  it "only Admin::Api (all actions) and SessionsController#show/#destroy accept an operator session" do
    Rails.application.eager_load!

    allowed = ApplicationController.descendants
      .select { |klass| klass.include?(Authentication) && klass.name.present? }
      .reject { |klass| klass.operator_grant_actions == [] }
      .to_h { |klass| [ klass.name, klass.operator_grant_actions ] }

    expect(allowed).to include("Admin::Api::BaseController" => :all, "SessionsController" => %i[show destroy])
    expect(allowed.keys - [ "SessionsController" ]).to all(start_with("Admin::Api::"))
    expect(allowed.except("SessionsController").values.uniq).to eq([ :all ])
  end
end
