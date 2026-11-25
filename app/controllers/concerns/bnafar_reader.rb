# Quem lê a situação, as remessas e as pendências do envio à BNAFAR (módulo
# 27b; contrato §6; Q32): o `municipal_admin`, o `stock_keeper` ou o
# `pharmacist` de QUALQUER local (papel válido: Membership ativa e vínculo
# ativo) e o `room_lead` de qualquer sala de vacina. O `pharmacy_assistant` e
# o vacinador não leem. Para o controller de
# Pharmacy::BaseController (usa `admin?` e `forbid`).
module BnafarReader
  private

  READER_ROLES = %w[stock_keeper pharmacist].freeze

  def bnafar_reader?
    admin? || stock_reader? || room_lead?
  end

  def stock_reader?
    Pharmacy::Access.roles_by_location(Current.user).values.any? { |roles| roles.intersect?(READER_ROLES) }
  end

  def room_lead?
    Vaccination::Access.rooms_for(Current.user).any? do |room|
      Vaccination::Access.room_roles(user: Current.user, room: room).include?("room_lead")
    end
  end

  # 403 missing_role e false; true se pode ler.
  def bnafar_reader!
    return true if bnafar_reader?

    forbid
    false
  end
end
