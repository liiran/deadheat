class OrderMailer < ApplicationMailer
  def confirmation(order)
    @order = order
    mail(to: order.user.email_address, subject: "Your Corner Store order")
  end
end
