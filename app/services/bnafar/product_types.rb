# DM13 pela sigla do programa de saúde (DM14) (módulo 27b, Valor 5).
module Bnafar
  module ProductTypes
    module_function

    # "B" | "E" | "S" | "O" | nil (sigla fora da DM14).
    def for(program_code) = index[program_code.to_s]

    def index = (@index ||= Domains.programs.to_h { |p| [p["code"], p["product_type"]] }.freeze)
    private_class_method :index
  end
end
