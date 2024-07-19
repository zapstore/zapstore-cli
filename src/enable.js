import { $ } from "bun";

export const enable = async (value) => {
  console.log('Unimplemented, please use install for now');
};

export const disable = async (value) => {
  await $`rm $NAME`.env({ NAME: value }).quiet();
  console.log('Disabled package', value);
};