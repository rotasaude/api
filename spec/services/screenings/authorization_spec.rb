# spec/services/screenings/authorization_spec.rb
require "rails_helper"

# ADR 0030 (spec §3.2; Desvio 2): papel, vínculo ativo na unidade e CBO dos
# grupos da escuta com ficha possível.
RSpec.describe Screenings::Authorization do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:unit) { create_unit }

  def check(user) = ApplicationRecord.transaction { described_class.check(user: user, health_unit_id: unit.id) }

  {
    "223505" => :ok, "225125" => :ok, "322205" => :ok, "322245" => :ok, "251605" => :ok,
    "223293" => :cbo_not_allowed, "322405" => :cbo_not_allowed, "221205" => :cbo_not_allowed
  }.each do |cbo, expected|
    it("CBO #{cbo} → #{expected}") { expect(check(screener!(unit, cbo: cbo)).first).to eq(expected) }
  end

  it "sem papel, sem vínculo na unidade, vínculo encerrado" do
    expect(check(staff_with("recepcao@cidade.gov.br", "citizen_verifier"))).to eq([ :missing_role, nil ])
    elsewhere = screener!(create_unit("UBS Outra"))
    expect(check(elsewhere)).to eq([ :missing_link, nil ])
    ended = screener!(unit)
    Professionals::EndLink.call(link: ended.professional.links.active.sole,
                                by: staff_with("adm-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin"))
    expect(check(ended)).to eq([ :missing_link, nil ])
  end

  it "com dois vínculos na unidade, prefere o de nível superior" do
    user = screener!(unit, cbo: "322205")
    link_professional!(user, unit, cbo: "223505")
    status, link = check(user)
    expect([ status, link.cbo_code ]).to eq([ :ok, "223505" ])
  end
end
