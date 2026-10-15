require "rails_helper"

# Desvio 1: o liberador tem perfil profissional sem ser health_professional.
RSpec.describe Professionals::Create do
  before { lab_city! }

  it "aceita lab_releaser; recusa quem não tem nenhum dos dois papéis" do
    user = staff_with("bio-#{SecureRandom.hex(3)}@cidade.gov.br", "lab_releaser")
    attrs = { professional_name: "Mariana Teles", council: "CRBM", council_state: "PR", registration_number: "12345",
              cns: Professionals::Cns.generate("bio") }
    expect(described_class.call(user_id: user.id, attrs: attrs, by: lab_admin!)).to be_ok
    staff = staff_with("staff-#{SecureRandom.hex(3)}@cidade.gov.br", "lab_staff")
    expect(described_class.call(user_id: staff.id, attrs: attrs.merge(registration_number: "999"), by: lab_admin!).reason).to eq(:user_missing_role)
  end
end
