require "rails_helper"

# Módulo 32b (ADR 0050; contrato §1 e §11): leitos e estadias da observação da UPA.
RSpec.describe "Esquema da observação da UPA", type: :model do
  let!(:city) { urgency_city! }
  let(:upa) { create_unit("UPA Obs", kind: "upa") }
  let(:doctor) { upa_doctor!(upa) }
  let(:bed) { UrgencyBed.create!(health_unit: upa, label: "OBS 01", updated_by_user: urgency_admin!) }

  def sp(&) = ApplicationRecord.transaction(requires_new: true, &)

  def in_care!
    e = arrived!(upa)
    classified!(e, color: "yellow", by: upa_nurse!(upa))
    called!(e, by: doctor)
    e.reload
  end

  def stay!(encounter, bed, at: Time.current)
    UrgencyBedStay.create!(urgency_encounter: encounter, urgency_bed: bed, health_unit: upa, started_at: at, started_by_user: doctor)
  end

  it "leito só na UPA, rótulo único por unidade e nunca apagado" do
    expect { UrgencyBed.create!(health_unit: create_unit("UBS"), label: "L1", updated_by_user: urgency_admin!) }
      .to raise_error(ActiveRecord::StatementInvalid, /only at an upa/)
    bed
    expect { UrgencyBed.create!(health_unit: upa, label: "OBS 01", updated_by_user: urgency_admin!) }.to raise_error(ActiveRecord::RecordNotUnique)
    expect { bed.delete }.to raise_error(ActiveRecord::StatementInvalid)
  end

  it "um ocupante por leito (exclusion); a troca no mesmo instante não sobrepõe" do
    a, b = in_care!, in_care!
    first = stay!(a, bed)
    expect { stay!(b, bed) }.to raise_error(ActiveRecord::StatementInvalid, /excl_urgency_bed_stays_bed/)
    now = Time.current
    first.update!(ended_at: now, end_kind: "bed_change", ended_by_user: doctor)
    expect { stay!(b, bed, at: now) }.not_to raise_error
  end

  it "nasce só com o encontro em atendimento; fechada nunca muda; uma aberta por encontro" do
    waiting = arrived!(upa)
    expect { stay!(waiting, bed) }.to raise_error(ActiveRecord::StatementInvalid, /not in care/)
    e = in_care!
    s = stay!(e, bed)
    expect { stay!(e, UrgencyBed.create!(health_unit: upa, label: "OBS 02", updated_by_user: urgency_admin!)) }
      .to raise_error(ActiveRecord::RecordNotUnique, /idx_urgency_bed_stays_open_encounter/)
    s.update!(ended_at: Time.current, end_kind: "observation_ended", ended_by_user: doctor)
    expect { s.update_column(:end_kind, "outcome") }.to raise_error(ActiveRecord::StatementInvalid, /closed stay never changes/)
  end

  describe "guardas do leito" do
    it "unidade e criação nunca mudam; TRUNCATE recusado" do
      bed
      other = create_unit("UPA Outra", kind: "upa")
      expect { sp { bed.update_column(:health_unit_id, other.id) } }.to raise_error(ActiveRecord::StatementInvalid, /never change/)
      expect { sp { bed.update_column(:created_at, 1.day.ago) } }.to raise_error(ActiveRecord::StatementInvalid, /never change/)
      expect { bed.update!(active: false) }.not_to raise_error
      expect { sp { ApplicationRecord.connection.execute("TRUNCATE urgency_beds CASCADE") } }.to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  describe "guardas da estadia" do
    it "aberta só recebe o fechamento; sem mudança é aceita; DELETE e TRUNCATE recusados" do
      e = in_care!
      s = stay!(e, bed)
      other_bed = UrgencyBed.create!(health_unit: upa, label: "OBS 02", updated_by_user: urgency_admin!)
      expect { sp { s.update_column(:started_at, 1.hour.ago) } }.to raise_error(ActiveRecord::StatementInvalid, /only receives the closing/)
      expect { sp { s.update_column(:urgency_bed_id, other_bed.id) } }.to raise_error(ActiveRecord::StatementInvalid, /only receives the closing/)
      expect { sp { s.update_column(:updated_at, Time.current) } }.to raise_error(ActiveRecord::StatementInvalid, /only receives the closing/)
      expect { sp { s.delete } }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
      expect { sp { ApplicationRecord.connection.execute("TRUNCATE urgency_bed_stays CASCADE") } }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "leito inativo, de outra unidade ou atendimento de outra unidade" do
      e = in_care!
      inactive = UrgencyBed.create!(health_unit: upa, label: "OBS 09", active: false, updated_by_user: urgency_admin!)
      other_upa = create_unit("UPA Outra", kind: "upa")
      foreign = UrgencyBed.create!(health_unit: other_upa, label: "OBS 01", updated_by_user: urgency_admin!)
      expect { sp { stay!(e, inactive) } }.to raise_error(ActiveRecord::StatementInvalid, /another unit or inactive/)
      expect { sp { stay!(e, foreign) } }.to raise_error(ActiveRecord::StatementInvalid, /another unit or inactive/)
      expect do
        sp { UrgencyBedStay.create!(urgency_encounter: e, urgency_bed: foreign, health_unit: other_upa, started_at: Time.current, started_by_user: doctor) }
      end.to raise_error(ActiveRecord::StatementInvalid, /another unit or inactive/)
    end

    it "nasce aberta" do
      e = in_care!
      expect do
        sp { UrgencyBedStay.create!(urgency_encounter: e, urgency_bed: bed, health_unit: upa, started_at: 1.hour.ago, ended_at: Time.current,
                               end_kind: "outcome", ended_by_user: doctor, started_by_user: doctor) }
      end.to raise_error(ActiveRecord::StatementInvalid, /born open/)
    end

    it "CHECKs do fechamento, do tempo e do tipo de saída" do
      s = stay!(in_care!, bed)
      expect { sp { s.update_columns(ended_at: Time.current) } }.to raise_error(ActiveRecord::StatementInvalid, /ck_urgency_bed_stays_closing/)
      expect { sp { s.update_columns(ended_at: s.started_at - 1.hour, end_kind: "outcome", ended_by_user_id: doctor.id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_urgency_bed_stays_times/)
      expect { sp { s.update_columns(ended_at: Time.current, end_kind: "bogus", ended_by_user_id: doctor.id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_urgency_bed_stays_end_kind/)
    end
  end
end
