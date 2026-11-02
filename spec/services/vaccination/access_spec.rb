require "rails_helper"

# Módulo 29 (ADR 0047, Desvio 6): o papel na sala vale com o vínculo ativo à
# sala E a Membership health_professional ativa E o ProfessionalLink ativo na
# unidade com CBO de vacinador. Cada um derruba o papel sozinho.
RSpec.describe Vaccination::Access do
  before { vaccination_city! }

  let(:unit) { create_unit("UBS Vacina") }
  let(:room) { vaccine_room!(unit) }

  def end_links!(user)
    ProfessionalLink.active.where(professional_id: user.professional.id)
                    .update_all(ended_at: Time.current, ended_by_user_id: pharmacy_admin!.id)
  end

  it "com os três, devolve o papel; room_lead exige o CBO 2235 e vaccinator aceita os da lista" do
    tecnica = room_member!(room)
    enfermeira = room_member!(room, role: "room_lead", cbo: "223505")
    expect(described_class.room_roles(user: tecnica, room: room)).to eq(Set["vaccinator"])
    expect(described_class.room_roles(user: enfermeira, room: room)).to eq(Set["room_lead"])
    expect(described_class.allowed?(user: enfermeira, room: room, roles: %w[room_lead])).to be(true)
    expect(described_class.allowed?(user: tecnica, room: room, roles: %w[room_lead])).to be(false)
    expect(described_class.allowed?(user: tecnica, room: room, roles: "vaccinator")).to be(true)
  end

  it "room_lead cujo vínculo deixou de ter o CBO 2235 perde o papel" do
    user = room_member!(room, role: "room_lead", cbo: "223505")
    end_links!(user)
    link_professional!(user, unit, cbo: "322205")
    expect(described_class.room_roles(user: user, room: room)).to be_empty
  end

  it "vínculo à sala revogado → vazio" do
    user = room_member!(room)
    VaccineRoomStaff.where(user_id: user.id).update_all(revoked_at: Time.current, revoked_by_user_id: pharmacy_admin!.id)
    expect(described_class.room_roles(user: user, room: room)).to be_empty
  end

  it "Membership health_professional revogada → vazio" do
    user = room_member!(room)
    user.memberships.where(role: "health_professional").update_all(revoked_at: Time.current)
    expect(described_class.room_roles(user: user, room: room)).to be_empty
  end

  it "ProfessionalLink encerrado → vazio; vínculo em outra unidade não vale" do
    user = room_member!(room)
    end_links!(user)
    expect(described_class.room_roles(user: user, room: room)).to be_empty
    expect(described_class.vaccinator_link(user: user, room: room)).to be_nil

    other = room_member!(room)
    end_links!(other)
    link_professional!(other, create_unit("Outra"), cbo: "322205")
    expect(described_class.room_roles(user: other, room: room)).to be_empty
  end

  it "CBO fora da lista de vacinador → vazio" do
    user = room_member!(room, cbo: "223405")
    expect(described_class.room_roles(user: user, room: room)).to be_empty
  end

  it "vaccinator_link devolve o vínculo ativo com CBO de vacinador na unidade" do
    user = room_member!(room)
    link = described_class.vaccinator_link(user: user, room: room)
    expect(link).to be_a(ProfessionalLink)
    expect(link.cbo_code).to eq("322205")
  end

  it "rooms_for devolve só salas ativas onde o papel vale" do
    user = room_member!(room)
    inactive = vaccine_room!
    VaccineRoomStaff.create!(vaccine_room: inactive, user: user, role: "vaccinator", granted_by_user: pharmacy_admin!, granted_at: Time.current)
    link_professional!(user, inactive.health_unit, cbo: "322205")
    inactive.update!(active: false)
    expect(described_class.rooms_for(user)).to eq([ room ])
  end
end
