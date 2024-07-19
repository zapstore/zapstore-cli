import { $ } from "bun";

export const link = async (value) => {
  console.log('Unimplemented, please use install for now');
};

export const unlink = async (value) => {
  await $`rm $NAME`.env({ NAME: value }).quiet();
  console.log('Unlinked package', value);
};