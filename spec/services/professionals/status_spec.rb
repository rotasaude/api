require "rails_helper"

RSpec.describe Professionals::Status do
  let(:admin) { staff_with("admin@cidade.gov.br", "municipal_admin") }

  def profile_for(user, cns)
    Professional.create!(user: user, professional_name: "P", council: "CRM", council_state: "PR",
                         registration_number: cns[-5..], cns: cns)
  end

  it "sem perfil, perfil sem vínculo ativo, e com vínculo ativo" do
    none = staff_with("a@c.gov.br", "health_professional")
    unlinked = staff_with("b@c.gov.br", "health_professional")
    linked = staff_with("c@c.gov.br", "health_professional")
    profile_for(unlinked, "700000000000005")
    ended = ProfessionalLink.create!(professional: profile_for(linked, "100000000000007"), health_unit: create_unit,
                                     cbo_code: "225125", started_at: Time.current, started_by_user: admin)
    expect(described_class.for_users([ none.id, unlinked.id, linked.id ]))
      .to eq(none.id => "missing_profile", unlinked.id => "missing_link", linked.id => "ok")

    ended.update!(ended_at: Time.current, ended_by_user: admin)
    expect(described_class.for_users([ linked.id ])).to eq(linked.id => "missing_link")
  end
end
