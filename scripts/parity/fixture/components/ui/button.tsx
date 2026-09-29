import { cva } from "class-variance-authority"
import { cn } from "@/lib/utils"

const buttonVariants = cva("inline-flex rounded-md", {
  variants: {
    variant: {
      default: "bg-primary text-primary-foreground",
      destructive: "bg-destructive",
      outline: "border",
    },
    size: {
      sm: "h-8 px-3",
      lg: "h-10 px-6",
    },
  },
})

export function Button({ className, variant, size, ...props }: any) {
  return <button className={cn(buttonVariants({ variant, size }), className)} {...props} />
}
