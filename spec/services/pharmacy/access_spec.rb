require "rails_helper"

# Módulo 27a (ADR 0045, Desvio 2): o papel da farmácia vale com a Membership
# ativa do mesmo papel E o vínculo ativo ao local. O farmacêutico do helper
# também tem health_professional (CBO 2234*): estes testes olham só os papéis
# da farmácia.
RSpec.describe Pharmacy::Access do
  before { pharmacy_city! }
  let(:central) { central_location! }
  let(:unit) { unit_location! }

  def revoke_link!(user, location, role)
    StockLocationStaff.active.find_by!(user: user, stock_location: location, role: role)
                      .update!(revoked_at: Time.current, revoked_by_user: pharmacy_admin!)
  end

  describe ".roles_at" do
    it "Membership e vínculo ativos: o papel do vínculo" do
      pharmacist = pharmacy_staff!(unit, "pharmacist")
      expect(described_class.roles_at(user: pharmacist, location: unit)).to eq(Set["pharmacist"])
    end

    it "o papel só vale no local do vínculo" do
      pharmacist = pharmacy_staff!(unit, "pharmacist")
      expect(described_class.roles_at(user: pharmacist, location: central)).to be_empty
    end

    it "Review Focus 4: Membership revogada com o vínculo ainda ativo: vazio" do
      pharmacist = pharmacy_staff!(unit, "pharmacist")
      pharmacist.memberships.active.find_by!(role: "pharmacist").revoke!
      expect(StockLocationStaff.active.where(user: pharmacist)).to exist
      expect(described_class.roles_at(user: pharmacist, location: unit)).to be_empty
      expect(described_class.allowed?(user: pharmacist, location: unit, roles: %w[pharmacist])).to be(false)
    end

    it "vínculo revogado com a Membership ativa: vazio" do
      assistant = pharmacy_staff!(unit, "pharmacy_assistant")
      revoke_link!(assistant, unit, "pharmacy_assistant")
      expect(assistant.has_role?("pharmacy_assistant")).to be(true)
      expect(described_class.roles_at(user: assistant, location: unit)).to be_empty
    end

    it "vínculo sem a Membership do papel nunca concede o papel" do
      keeper = staff_with("sem-papel-#{SecureRandom.hex(2)}@cidade.gov.br")
      StockLocationStaff.create!(stock_location: unit, user: keeper, role: "stock_keeper", granted_by_user: pharmacy_admin!, granted_at: Time.current)
      expect(described_class.roles_at(user: keeper, location: unit)).to be_empty
    end

    it "dois papéis no mesmo local: só os que têm Membership ativa" do
      user = pharmacy_staff!(unit, "pharmacist")
      Membership.create!(user: user, role: "stock_keeper", granted_at: Time.current)
      StockLocationStaff.create!(stock_location: unit, user: user, role: "stock_keeper", granted_by_user: pharmacy_admin!, granted_at: Time.current)
      StockLocationStaff.create!(stock_location: unit, user: user, role: "pharmacy_assistant", granted_by_user: pharmacy_admin!, granted_at: Time.current)
      expect(described_class.roles_at(user: user, location: unit)).to eq(Set["pharmacist", "stock_keeper"])
    end

    it "o papel de outra pessoa no mesmo local não vaza" do
      pharmacy_staff!(unit, "pharmacist")
      other = pharmacy_staff!(unit, "pharmacy_assistant")
      expect(described_class.roles_at(user: other, location: unit)).to eq(Set["pharmacy_assistant"])
    end
  end

  describe ".allowed?" do
    it "verdadeiro quando algum dos papéis pedidos vale no local" do
      keeper = pharmacy_staff!(central, "stock_keeper")
      expect(described_class.allowed?(user: keeper, location: central, roles: %w[stock_keeper pharmacist])).to be(true)
      expect(described_class.allowed?(user: keeper, location: central, roles: %w[pharmacist pharmacy_assistant])).to be(false)
      expect(described_class.allowed?(user: keeper, location: unit, roles: %w[stock_keeper])).to be(false)
    end
  end

  describe ".central_keeper?" do
    it "só com vínculo stock_keeper no local central" do
      expect(described_class.central_keeper?(pharmacy_staff!(central, "stock_keeper"))).to be(true)
      expect(described_class.central_keeper?(pharmacy_staff!(unit, "stock_keeper"))).to be(false)
      expect(described_class.central_keeper?(pharmacy_staff!(unit, "pharmacist"))).to be(false)
    end

    it "o vínculo de outro papel no central não basta" do
      central_pharmacist = pharmacy_staff!(central, "pharmacist")
      expect(described_class.central_keeper?(central_pharmacist)).to be(false)
    end

    it "Membership revogada ou vínculo revogado: deixa de ser" do
      by_membership = pharmacy_staff!(central, "stock_keeper")
      by_link = pharmacy_staff!(central, "stock_keeper")
      by_membership.memberships.active.find_by!(role: "stock_keeper").revoke!
      revoke_link!(by_link, central, "stock_keeper")
      expect(described_class.central_keeper?(by_membership)).to be(false)
      expect(described_class.central_keeper?(by_link)).to be(false)
    end
  end

  describe ".locations_for" do
    it "o central keeper vê todos os locais ativos" do
      keeper = pharmacy_staff!(central, "stock_keeper")
      first_unit = unit
      other_unit = unit_location!
      inactive = unit_location!
      inactive.update!(active: false)
      expect(described_class.locations_for(keeper)).to match_array([ central, first_unit, other_unit ])
    end

    it "os demais veem os ativos onde têm papel" do
      pharmacist = pharmacy_staff!(unit, "pharmacist")
      closed = unit_location!
      StockLocationStaff.create!(stock_location: closed, user: pharmacist, role: "pharmacist", granted_by_user: pharmacy_admin!, granted_at: Time.current)
      closed.update!(active: false)
      expect(described_class.locations_for(pharmacist)).to eq([ unit ])
    end

    it "papel sem Membership não lista o local; sem vínculo, lista vazia" do
      pharmacist = pharmacy_staff!(unit, "pharmacist")
      pharmacist.memberships.active.find_by!(role: "pharmacist").revoke!
      expect(described_class.locations_for(pharmacist)).to be_empty
      expect(described_class.locations_for(staff_with("ninguem-#{SecureRandom.hex(2)}@cidade.gov.br"))).to be_empty
    end
  end
end
