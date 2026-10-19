# Nome do órgão de saúde que aparece na tela de login da cidade (spec
# identidade da cidade). Opcional; o limite de 120 também é validado no model.
class AddHealthDepartmentNameToCities < ActiveRecord::Migration[8.1]
  def change
    add_column :cities, :health_department_name, :string, limit: 120
  end
end
