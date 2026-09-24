require "rails_helper"

RSpec.describe Attendance do
  before { Current.city = TEST_CITY_A }
  after { Current.reset; Rails.cache.clear }

  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:staff) { User.create!(email_address: "atendente@cidade.gov.br", password: "senha-segura-123") }
  let(:unit) { create_unit }
  let(:triage) { completed_web_triage_for(citizen) }

  def open!(**attrs)
    described_class.create!({ triage: triage, citizen: citizen, health_unit: unit, checked_in_by_user: staff,
                              checked_in_at: Time.current, check_in_method: "code" }.merge(attrs))
  end

  it "um atendimento por triagem" do
    open!
    expect { open! }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "exceção exige motivo com 10 caracteres" do
    expect { open!(check_in_method: "cpf_exception", exception_reason: "curto") }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_attendances_exception_reason/)
    expect { open!(check_in_method: "cpf_exception", exception_reason: "cidadão sem celular") }.not_to raise_error
  end

  it "encerra uma vez; encaminhado exige destino ou descrição" do
    a = open!
    expect { a.update!(status: "closed", outcome: "referred", closed_by_user: staff, closed_at: Time.current) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_attendances_referral/)
    a.reload.update!(status: "closed", outcome: "referred", referral_note: "cardiologia", closed_by_user: staff,
                     closed_at: Time.current)
    expect { a.update!(outcome: "left") }.to raise_error(ActiveRecord::StatementInvalid, /already closed/)
  end

  it "não apaga e não muda o check-in" do
    a = open!
    expect { described_class.transaction(requires_new: true) { a.delete } }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    other = create_unit("UPA Norte", kind: "upa")
    expect { described_class.transaction(requires_new: true) { a.update_column(:health_unit_id, other.id) } }
      .to raise_error(ActiveRecord::StatementInvalid, /check-in columns/)
  end
end
