require "rails_helper"
require Rails.root.join("db/city_migrate/20261006100001_add_professional_schedules.rb").to_s

# ADR 0029 (Consequências): a migração recusa seguir com horários `slot` ativos
# sobrepostos herdados, listando os ids. Num savepoint: tira a EXCLUDE, grava a
# sobreposição e chama a verificação que o up() roda antes de recriá-la.
RSpec.describe "Migração de cidade 20261006100001 (AddProfessionalSchedules): sobreposição herdada" do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:conn) { ApplicationRecord.connection }

  it "sem sobreposição passa; com sobreposição aborta listando os dois ids" do
    expect { AddProfessionalSchedules.assert_no_inherited_overlap!(conn) }.not_to raise_error

    ApplicationRecord.transaction(requires_new: true) do
      conn.execute("ALTER TABLE appointments DROP CONSTRAINT excl_appointments_slot_overlap")
      unit = create_unit
      shift = shift!(doctor_link!(unit), starts_at: 2.days.from_now.change(hour: 8))
      a = appointment_row!(triage_request!(Citizen.create!(cpf: "52998224725", phone: "+5541998765432"), unit: unit),
                           shift, starts_at: shift.starts_at)
      b = appointment_row!(triage_request!(Citizen.create!(cpf: "11144477735", phone: "+5541911112222"), unit: unit),
                           shift, starts_at: shift.starts_at + 5.minutes)

      expect(AddProfessionalSchedules.inherited_overlaps(conn)).to eq([ [ a.id, b.id ].sort ])
      expect { AddProfessionalSchedules.assert_no_inherited_overlap!(conn) }
        .to raise_error(AddProfessionalSchedules::InheritedOverlap, /#{a.id}.*#{b.id}|#{b.id}.*#{a.id}/)
      raise ActiveRecord::Rollback
    end
  end
end
