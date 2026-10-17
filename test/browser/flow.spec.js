import { test, expect } from '@playwright/test';
const settings=async page=>page.getByRole('button',{name:'Settings',exact:true}).click();
const map=async page=>page.getByRole('button',{name:'Map',exact:true}).click();
test('map-first simulated nonresponse, privacy, acknowledgment, activity and end sharing',async({page,context})=>{
 const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto('/');await page.locator('#consent').check();await page.getByRole('button',{name:'Try a 15-second simulated session'}).click();
 await expect(page.locator('#person-name')).toHaveText('Alex');await expect(page.locator('#empty-location')).toBeVisible();
 await settings(page);const link=await page.getByRole('link',{name:'Open guardian page'}).getAttribute('href');
 const helper=await context.newPage();await helper.goto(link);await expect(helper.locator('#private-message')).toBeVisible();await expect(helper.locator('.person-marker')).toHaveCount(0);
 await page.getByRole('button',{name:'Add sample geographic route'}).click();await map(page);await expect(page.locator('.person-marker')).toHaveCount(1);await expect(page.locator('#location-status')).toContainText('reported accuracy 8 m');
 await page.getByRole('button',{name:'Check in',exact:true}).click();await expect(page.locator('#message')).toContainText('confirmed by server');
 await page.getByRole('button',{name:'Activity',exact:true}).click();await expect(page.locator('#activity')).toContainText('Check-in accepted by server');
 await map(page);await page.screenshot({path:'artifacts/desktop-map.png',fullPage:true});
 await expect(helper.locator('#phase-pill')).toHaveText('Check-in unanswered',{timeout:25000});await expect(helper.locator('.person-marker')).toHaveCount(1);
 await helper.getByRole('button',{name:"I've seen the request"}).click();await expect(helper.locator('#response-status')).toContainText('Arrival is not verified');
 await expect(helper.getByRole('link',{name:'Directions to last point'})).toHaveAttribute('href',/google.com\/maps/);
 await helper.getByRole('button',{name:'Open camera direction preview'}).click();await expect(helper.locator('#message')).not.toBeEmpty();await expect(helper.locator('#phase-pill')).toHaveText('Check-in unanswered');
 await settings(page);await page.getByRole('button',{name:'End session and stop sharing'}).click();
 await expect(helper.locator('#phase-pill')).toHaveText('Session ended');await expect(helper.locator('.person-marker')).toHaveCount(0);expect(errors).toEqual([]);
});
test('device onboarding, no-location fallback and accessible mobile navigation',async({page})=>{
 await page.setViewportSize({width:390,height:844});await page.goto('/');await page.locator('#consent').check();await page.getByRole('button',{name:'Create device session',exact:true}).click();
 await expect(page.locator('#session-description')).toContainText('readings appear only after a device connects');await expect(page.locator('#empty-location')).toBeVisible();await expect(page.locator('.person-marker')).toHaveCount(0);
 expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);await page.screenshot({path:'artifacts/mobile-map.png',fullPage:true});
 await settings(page);await expect(page.locator('#demo-controls')).toBeHidden();await expect(page.locator('#sources')).toContainText('No readings');
});
test('explicit live sharing can be revoked and guardian clears cached evidence',async({page,context})=>{
 await page.goto('/');await page.locator('#consent').check();await page.locator('#live-sharing').check();await page.getByRole('button',{name:'Try a 15-second simulated session'}).click();
 await settings(page);const link=await page.locator('#guardian-link').getAttribute('href');await page.getByRole('button',{name:'Add sample geographic route'}).click();
 const helper=await context.newPage();await helper.goto(link);await expect(helper.locator('.person-marker')).toHaveCount(1);
 await page.getByRole('button',{name:'Revoke guardian access'}).click();await expect(helper.locator('#message')).toContainText('revoked');await expect(helper.locator('#dashboard')).toBeHidden();await expect(helper.locator('.person-marker')).toHaveCount(0);
});
