# Quem lê a situação, as remessas e as pendências do envio à BNAFAR (módulo
# 27b; contrato §6): o `municipal_admin` ou o `stock_keeper` de QUALQUER local
# (papel válido: Membership ativa e vínculo ativo). Para o controller de
# Pharmacy::BaseController (usa `admin?` e `forbid`).
module BnafarReader
  private

  def bnafar_reader?
    admin? || Pharmacy::Access.roles_by_location(Current.user).values.any? { |roles| roles.include?("stock_keeper") }
  end

  # 403 missing_role e false; true se pode ler.
  def bnafar_reader!
    return true if bnafar_reader?

    forbid
    false
  end
end
